// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include "legacy_config/LegacyConfig.hpp"
#include <iostream>
#include <string>

int main() {
    std::string line;
    while (std::getline(std::cin, line)) {
        try {
            std::cout << legacy::Decode(line).dump() << '\n';
        } catch (const std::exception& e) {
            std::cout << nlohmann::json{{"error", e.what()}}.dump() << '\n';
        }
    }
}
