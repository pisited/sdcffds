#pragma once

// Portable, side-effect-free policy. It neither owns nor discovers processes.
#include <cstdint>
#include <stdexcept>

namespace beamrt { namespace unattended {

struct WatchdogConfig {
    std::uint64_t overallMilliseconds = 0;
    std::uint64_t normalGraceMilliseconds = 0;
    std::uint32_t terminationWaitMilliseconds = 0;
    bool forceCloseAuthorized = false;
};

inline void ValidateWatchdogConfig(const WatchdogConfig& config) {
    if (config.overallMilliseconds < 1 || config.overallMilliseconds > 480000 ||
        config.normalGraceMilliseconds < 1 || config.normalGraceMilliseconds > 30000 ||
        config.terminationWaitMilliseconds < 1 || config.terminationWaitMilliseconds > 10000) {
        throw std::invalid_argument("watchdog limits are missing or outside the bounded contract");
    }
}

enum class WatchdogAction { None, RequestNormal, ForceClose };

// Clock input is elapsed wall time from immediately BEFORE creation, not from
// a later map-ready or first-poll event. No API calls or sleeps occur here.
class WatchdogPolicy final {
public:
    explicit WatchdogPolicy(const WatchdogConfig& config) : config_(config) {
        ValidateWatchdogConfig(config_);
    }

    WatchdogAction Step(std::uint64_t elapsed, bool exitVerified, bool stopRequested) {
        if (exitVerified) { exitVerified_ = true; return WatchdogAction::None; }
        if (exitVerified_) return WatchdogAction::None;
        // A bad injected clock fails toward requesting stop, never toward an
        // immediate force action or shortening the normal grace window.
        if (elapsed < lastElapsed_) { stopRequested = true; elapsed = lastElapsed_; }
        lastElapsed_ = elapsed;
        if (!normalRequested_ && (stopRequested || elapsed >= config_.overallMilliseconds)) {
            normalRequested_ = true;
            normalAt_ = elapsed;
            return WatchdogAction::RequestNormal;
        }
        if (normalRequested_ && elapsed - normalAt_ >= config_.normalGraceMilliseconds) {
            graceExpired_ = true;
            if (config_.forceCloseAuthorized && !forceIssued_) {
                forceIssued_ = true;
                return WatchdogAction::ForceClose;
            }
        }
        return WatchdogAction::None;
    }

    bool NormalRequested() const noexcept { return normalRequested_; }
    bool ForceIssued() const noexcept { return forceIssued_; }
    bool GraceExpired() const noexcept { return graceExpired_; }
    bool ForceAuthorized() const noexcept { return config_.forceCloseAuthorized; }
    std::uint64_t NormalAt() const noexcept { return normalAt_; }

private:
    WatchdogConfig config_;
    std::uint64_t lastElapsed_ = 0;
    std::uint64_t normalAt_ = 0;
    bool normalRequested_ = false;
    bool graceExpired_ = false;
    bool forceIssued_ = false;
    bool exitVerified_ = false;
};

} } // namespace beamrt::unattended
