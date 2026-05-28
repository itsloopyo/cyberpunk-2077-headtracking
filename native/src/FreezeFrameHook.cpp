#include "FreezeFrameHook.hpp"
#include "AimCompensation.hpp"   // LogInfo / LogWarning / LogError
#include "SharedState.hpp"

#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <atomic>
#include <cstdint>

#pragma comment(lib, "d3d12.lib")
#pragma comment(lib, "dxgi.lib")

namespace {

// Vtable indices.
//   IDXGISwapChain::Present            = 8
//   ID3D12CommandQueue::ExecuteCommandLists = 10
constexpr size_t kVtblIdx_SwapChain_Present = 8;
constexpr size_t kVtblIdx_Queue_Execute     = 10;

// Number of frames to hold the duplicate after a SNAP-CLEAN. The snap renders
// on the fire frame; 2 covers a one-frame timing slop between the Lua observer
// and the rendered/presented frame.
constexpr uint32_t kFreezeFrames = 2;

using Present_t = HRESULT (STDMETHODCALLTYPE*)(IDXGISwapChain3*, UINT, UINT);
using Execute_t = void    (STDMETHODCALLTYPE*)(ID3D12CommandQueue*, UINT, ID3D12CommandList* const*);

Present_t g_origPresent = nullptr;
Execute_t g_origExec    = nullptr;
void**    g_slotPresent = nullptr;
void**    g_slotExec    = nullptr;

std::atomic<bool> g_started{false};

// Captured from the game on first ExecuteCommandLists. The swapchain presents
// on the queue it was created with; the game's main render queue is the first
// one we see and is the present queue in practice.
ID3D12CommandQueue* g_gameQueue = nullptr;

// Lazily created copy machinery (on first Present).
bool                     g_inited       = false;
ID3D12Device*            g_device       = nullptr;
ID3D12Resource*          g_prevFrame    = nullptr;   // rolling copy of last good frame
ID3D12CommandAllocator*  g_alloc        = nullptr;
ID3D12GraphicsCommandList* g_cmdList     = nullptr;
ID3D12Fence*             g_fence        = nullptr;
UINT64                   g_fenceVal     = 0;
HANDLE                   g_fenceEvent   = nullptr;
DXGI_FORMAT              g_bbFormat     = DXGI_FORMAT_UNKNOWN;
UINT64                   g_bbWidth      = 0;
UINT                     g_bbHeight     = 0;

uint32_t g_lastRestoreSeq = 0;
uint32_t g_freezeFrames   = 0;
bool     g_seqPrimed      = false;

// ---------------------------------------------------------------------------
bool PatchVtableSlot(void** vtbl, size_t idx, void* detour, void** outOriginal, void*** outSlot) {
    void** slot = &vtbl[idx];
    DWORD oldp = 0;
    if (!VirtualProtect(slot, sizeof(void*), PAGE_READWRITE, &oldp)) return false;
    *outOriginal = *slot;          // store original BEFORE installing the detour
    *slot = detour;
    DWORD tmp = 0;
    VirtualProtect(slot, sizeof(void*), oldp, &tmp);
    *outSlot = slot;
    return true;
}

void UnpatchVtableSlot(void** slot, void* original) {
    if (!slot) return;
    DWORD oldp = 0;
    if (VirtualProtect(slot, sizeof(void*), PAGE_READWRITE, &oldp)) {
        *slot = original;
        DWORD tmp = 0;
        VirtualProtect(slot, sizeof(void*), oldp, &tmp);
    }
}

void Barrier(ID3D12GraphicsCommandList* cl, ID3D12Resource* res,
             D3D12_RESOURCE_STATES from, D3D12_RESOURCE_STATES to) {
    D3D12_RESOURCE_BARRIER b = {};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource   = res;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore = from;
    b.Transition.StateAfter  = to;
    cl->ResourceBarrier(1, &b);
}

// Create prevFrame texture matching the backbuffer + the copy command objects.
bool LazyInit(IDXGISwapChain3* sc) {
    if (g_inited) return true;
    if (!g_gameQueue) return false;   // need the game's queue first

    if (FAILED(sc->GetDevice(IID_PPV_ARGS(&g_device))) || !g_device) {
        LogError("[FreezeFrame] GetDevice failed");
        return false;
    }

    ID3D12Resource* bb = nullptr;
    UINT idx = sc->GetCurrentBackBufferIndex();
    if (FAILED(sc->GetBuffer(idx, IID_PPV_ARGS(&bb))) || !bb) {
        LogError("[FreezeFrame] GetBuffer(0) failed");
        return false;
    }
    D3D12_RESOURCE_DESC desc = bb->GetDesc();
    bb->Release();
    g_bbFormat = desc.Format;
    g_bbWidth  = desc.Width;
    g_bbHeight = desc.Height;

    D3D12_HEAP_PROPERTIES hp = {};
    hp.Type = D3D12_HEAP_TYPE_DEFAULT;
    // prevFrame mirrors the backbuffer but is a plain copy target (no RT flag).
    D3D12_RESOURCE_DESC td = desc;
    td.Flags = D3D12_RESOURCE_FLAG_NONE;
    if (FAILED(g_device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &td,
                D3D12_RESOURCE_STATE_COMMON, nullptr, IID_PPV_ARGS(&g_prevFrame)))) {
        LogError("[FreezeFrame] CreateCommittedResource(prevFrame) failed");
        return false;
    }

    if (FAILED(g_device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&g_alloc)))
     || FAILED(g_device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, g_alloc, nullptr, IID_PPV_ARGS(&g_cmdList)))
     || FAILED(g_device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&g_fence)))) {
        LogError("[FreezeFrame] command-object creation failed");
        return false;
    }
    g_cmdList->Close();
    g_fenceEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    g_inited = true;
    LogInfo("[FreezeFrame] initialized: %llux%u fmt=%d", (unsigned long long)g_bbWidth, g_bbHeight, (int)g_bbFormat);
    return true;
}

void DoCopy(IDXGISwapChain3* sc, bool restore) {
    UINT idx = sc->GetCurrentBackBufferIndex();
    ID3D12Resource* bb = nullptr;
    if (FAILED(sc->GetBuffer(idx, IID_PPV_ARGS(&bb))) || !bb) return;

    // Wait for the previous frame's copy so the allocator is reusable.
    if (g_fence->GetCompletedValue() < g_fenceVal) {
        g_fence->SetEventOnCompletion(g_fenceVal, g_fenceEvent);
        WaitForSingleObject(g_fenceEvent, 100);
    }
    g_alloc->Reset();
    g_cmdList->Reset(g_alloc, nullptr);

    if (restore) {
        // prevFrame -> backbuffer (show the saved good frame)
        Barrier(g_cmdList, bb,          D3D12_RESOURCE_STATE_PRESENT,     D3D12_RESOURCE_STATE_COPY_DEST);
        Barrier(g_cmdList, g_prevFrame, D3D12_RESOURCE_STATE_COMMON,      D3D12_RESOURCE_STATE_COPY_SOURCE);
        g_cmdList->CopyResource(bb, g_prevFrame);
        Barrier(g_cmdList, g_prevFrame, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_COMMON);
        Barrier(g_cmdList, bb,          D3D12_RESOURCE_STATE_COPY_DEST,   D3D12_RESOURCE_STATE_PRESENT);
    } else {
        // backbuffer -> prevFrame (roll the saved frame forward)
        Barrier(g_cmdList, bb,          D3D12_RESOURCE_STATE_PRESENT,     D3D12_RESOURCE_STATE_COPY_SOURCE);
        Barrier(g_cmdList, g_prevFrame, D3D12_RESOURCE_STATE_COMMON,      D3D12_RESOURCE_STATE_COPY_DEST);
        g_cmdList->CopyResource(g_prevFrame, bb);
        Barrier(g_cmdList, g_prevFrame, D3D12_RESOURCE_STATE_COPY_DEST,   D3D12_RESOURCE_STATE_COMMON);
        Barrier(g_cmdList, bb,          D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_PRESENT);
    }

    g_cmdList->Close();
    ID3D12CommandList* lists[] = { g_cmdList };
    g_gameQueue->ExecuteCommandLists(1, lists);   // ordered before Present on the same queue
    g_gameQueue->Signal(g_fence, ++g_fenceVal);
    bb->Release();
}

HRESULT STDMETHODCALLTYPE HOOK_Present(IDXGISwapChain3* This, UINT SyncInterval, UINT Flags) {
    if (LazyInit(This)) {
        // Resolution change invalidates prevFrame; skip until re-init (rare).
        ID3D12Resource* bb = nullptr;
        if (SUCCEEDED(This->GetBuffer(This->GetCurrentBackBufferIndex(), IID_PPV_ARGS(&bb))) && bb) {
            D3D12_RESOURCE_DESC d = bb->GetDesc();
            bb->Release();
            if (d.Width == g_bbWidth && d.Height == g_bbHeight && d.Format == g_bbFormat) {
                HeadTrackingState* s = g_sharedState.GetWritable();
                if (s) {
                    uint32_t seq = s->restore_req_seq;
                    if (!g_seqPrimed) { g_lastRestoreSeq = seq; g_seqPrimed = true; }
                    if (seq != g_lastRestoreSeq) {
                        g_lastRestoreSeq = seq;
                        // freeze_frame_enabled=0 leaves the snap visible (video capture mode).
                        // Backbuffer copy keeps running below so re-enabling is seamless.
                        if (s->freeze_frame_enabled != 0u) {
                            g_freezeFrames = kFreezeFrames;
                        }
                    }
                }
                bool restore = g_freezeFrames > 0;
                DoCopy(This, restore);
                if (restore && g_freezeFrames > 0) g_freezeFrames--;
            }
        }
    }
    return g_origPresent(This, SyncInterval, Flags);
}

void STDMETHODCALLTYPE HOOK_Exec(ID3D12CommandQueue* This, UINT n, ID3D12CommandList* const* lists) {
    if (!g_gameQueue && This) {
        D3D12_COMMAND_QUEUE_DESC qd = This->GetDesc();
        if (qd.Type == D3D12_COMMAND_LIST_TYPE_DIRECT) {
            g_gameQueue = This;
            LogInfo("[FreezeFrame] captured game command queue %p", This);
        }
    }
    g_origExec(This, n, lists);
}

// ---------------------------------------------------------------------------
// Steal Present + ExecuteCommandLists vtables via a throwaway device + queue +
// swapchain (needs a temporary window for the swapchain).
bool DiscoverAndPatch() {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"HTFreezeFrameDummy";
    RegisterClassExW(&wc);
    HWND hwnd = CreateWindowExW(0, wc.lpszClassName, L"", WS_OVERLAPPEDWINDOW,
                                0, 0, 8, 8, nullptr, nullptr, wc.hInstance, nullptr);
    if (!hwnd) { LogError("[FreezeFrame] dummy window failed"); return false; }

    bool ok = false;
    IDXGIFactory2* factory = nullptr;
    ID3D12Device* device = nullptr;
    ID3D12CommandQueue* queue = nullptr;
    IDXGISwapChain1* sc1 = nullptr;
    IDXGISwapChain3* sc3 = nullptr;

    do {
        if (FAILED(CreateDXGIFactory2(0, IID_PPV_ARGS(&factory)))) break;
        if (FAILED(D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device)))) break;
        D3D12_COMMAND_QUEUE_DESC qd = {};
        qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        if (FAILED(device->CreateCommandQueue(&qd, IID_PPV_ARGS(&queue)))) break;

        DXGI_SWAP_CHAIN_DESC1 sd = {};
        sd.Width = 8; sd.Height = 8;
        sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        sd.SampleDesc.Count = 1;
        sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        sd.BufferCount = 2;
        sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        if (FAILED(factory->CreateSwapChainForHwnd(queue, hwnd, &sd, nullptr, nullptr, &sc1))) break;
        if (FAILED(sc1->QueryInterface(IID_PPV_ARGS(&sc3)))) break;

        void** scVtbl    = *reinterpret_cast<void***>(sc3);
        void** queueVtbl = *reinterpret_cast<void***>(queue);

        ok = PatchVtableSlot(scVtbl, kVtblIdx_SwapChain_Present,
                             reinterpret_cast<void*>(&HOOK_Present),
                             reinterpret_cast<void**>(&g_origPresent), &g_slotPresent)
          && PatchVtableSlot(queueVtbl, kVtblIdx_Queue_Execute,
                             reinterpret_cast<void*>(&HOOK_Exec),
                             reinterpret_cast<void**>(&g_origExec), &g_slotExec);
        if (ok) {
            LogInfo("[FreezeFrame] vtable patched: Present=%p Exec=%p (orig)",
                    (void*)g_origPresent, (void*)g_origExec);
        }
    } while (false);

    if (sc3) sc3->Release();
    if (sc1) sc1->Release();
    if (queue) queue->Release();
    if (device) device->Release();
    if (factory) factory->Release();
    DestroyWindow(hwnd);
    UnregisterClassW(wc.lpszClassName, wc.hInstance);
    return ok;
}

} // namespace

bool FreezeFrameHook_Start() {
    if (g_started.exchange(true)) return true;
    if (!DiscoverAndPatch()) {
        LogError("[FreezeFrame] discover/patch failed - disabled");
        g_started = false;
        return false;
    }
    LogInfo("[FreezeFrame] active - Present/ExecuteCommandLists detoured");
    return true;
}

void FreezeFrameHook_Stop() {
    if (!g_started.exchange(false)) return;
    UnpatchVtableSlot(g_slotPresent, reinterpret_cast<void*>(g_origPresent));
    UnpatchVtableSlot(g_slotExec,    reinterpret_cast<void*>(g_origExec));
    g_slotPresent = g_slotExec = nullptr;
    // Leave g_prevFrame etc. allocated; process is tearing down.
}
