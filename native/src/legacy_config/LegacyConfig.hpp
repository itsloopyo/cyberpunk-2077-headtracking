// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once

#include <nlohmann/json.hpp>
#include <string>

namespace legacy {
nlohmann::json Defaults();
nlohmann::json Decode(const std::string& bytes);
}
