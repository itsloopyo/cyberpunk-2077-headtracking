#pragma once

// Freeze-frame mask for the SNAP-CLEAN click flick.
//
// On a fire frame the engine renders the camera snapped to the clean
// (mouse-aim) orientation for one frame, producing a visible flick. Instead
// of masking it with an opaque overlay (a black/dim frame), we hold a rolling
// copy of the last good rendered frame and blit it over the snapped frame, so
// the player sees a single duplicate frame rather than a flash.
//
// Mechanism: hook IDXGISwapChain::Present and ID3D12CommandQueue::
// ExecuteCommandLists (to capture the game's command queue). Each Present,
// copy the current backbuffer into a saved texture; when SharedState's
// restore_req_seq just changed (a SNAP-CLEAN fired), instead copy the saved
// texture back over the backbuffer for a couple of frames.

bool FreezeFrameHook_Start();
void FreezeFrameHook_Stop();
