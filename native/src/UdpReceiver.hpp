#pragma once
#include <cstdint>

bool UdpReceiver_Start(uint16_t port);
void UdpReceiver_Stop();
void UdpReceiver_PublishLatest();
bool UdpReceiver_TryConsumeRecenterRequest();
