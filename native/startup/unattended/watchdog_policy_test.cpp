#include "watchdog_policy.h"

#include <iostream>
#include <stdexcept>
#include <string>

using beamrt::unattended::WatchdogAction;
using beamrt::unattended::WatchdogConfig;
using beamrt::unattended::WatchdogPolicy;

namespace {
unsigned cases = 0;
unsigned assertions = 0;
void Check(bool condition, const char* message) {
    ++assertions;
    if (!condition) throw std::runtime_error(message);
}
template<class Body> void Case(const char* name, Body body) {
    try { body(); ++cases; }
    catch (const std::exception& error) { throw std::runtime_error(std::string(name) + ": " + error.what()); }
}
void Invalid(WatchdogConfig config) {
    bool rejected = false;
    try { WatchdogPolicy policy(config); (void)policy; }
    catch (const std::invalid_argument&) { rejected = true; }
    Check(rejected, "invalid limits accepted");
}
WatchdogConfig Valid(bool authorized = true) { return {100, 30, 10, authorized}; }
}

int main() {
    try {
        Case("missing limits", [] { Invalid({}); });
        Case("zero overall", [] { auto config = Valid(); config.overallMilliseconds = 0; Invalid(config); });
        Case("large overall", [] { auto config = Valid(); config.overallMilliseconds = 480001; Invalid(config); });
        Case("zero grace", [] { auto config = Valid(); config.normalGraceMilliseconds = 0; Invalid(config); });
        Case("large grace", [] { auto config = Valid(); config.normalGraceMilliseconds = 30001; Invalid(config); });
        Case("zero termination wait", [] { auto config = Valid(); config.terminationWaitMilliseconds = 0; Invalid(config); });
        Case("large termination wait", [] { auto config = Valid(); config.terminationWaitMilliseconds = 10001; Invalid(config); });
        Case("minimum limits", [] { WatchdogPolicy policy({1, 1, 1, true}); Check(!policy.NormalRequested(), "side effect at construction"); });
        Case("maximum limits", [] { WatchdogPolicy policy({480000, 30000, 10000, false}); Check(!policy.ForceAuthorized(), "implicit force authority"); });
        Case("construction inert", [] {
            WatchdogPolicy policy(Valid());
            Check(!policy.NormalRequested() && !policy.ForceIssued() && !policy.GraceExpired(), "policy constructed active");
        });
        Case("before deadline", [] {
            WatchdogPolicy policy(Valid());
            Check(policy.Step(0, false, false) == WatchdogAction::None, "early normal");
            Check(policy.Step(99, false, false) == WatchdogAction::None, "early deadline");
        });
        Case("deadline normal first", [] {
            WatchdogPolicy policy(Valid());
            Check(policy.Step(100, false, false) == WatchdogAction::RequestNormal, "missing normal request");
            Check(policy.NormalAt() == 100 && !policy.ForceIssued(), "incorrect deadline origin");
        });
        Case("no retry normal", [] {
            WatchdogPolicy policy(Valid());
            Check(policy.Step(2, false, true) == WatchdogAction::RequestNormal, "missing explicit stop");
            Check(policy.Step(2, false, true) == WatchdogAction::None, "normal retried");
            Check(policy.Step(3, false, true) == WatchdogAction::None, "normal retried later");
        });
        Case("full grace", [] {
            WatchdogPolicy policy(Valid());
            policy.Step(100, false, false);
            Check(policy.Step(129, false, false) == WatchdogAction::None, "force skipped grace");
            Check(policy.Step(130, false, false) == WatchdogAction::ForceClose, "missing force at grace");
        });
        Case("force once only", [] {
            WatchdogPolicy policy(Valid());
            policy.Step(100, false, false); policy.Step(130, false, false);
            Check(policy.Step(131, false, true) == WatchdogAction::None, "force retried");
            Check(policy.Step(900000, false, true) == WatchdogAction::None, "force retried after failure");
        });
        Case("no authority no force", [] {
            WatchdogPolicy policy(Valid(false));
            Check(policy.Step(100, false, false) == WatchdogAction::RequestNormal, "normal lost without authority");
            Check(policy.Step(130, false, false) == WatchdogAction::None, "unauthorized force");
            Check(policy.GraceExpired() && !policy.ForceIssued(), "unconfirmed state not explicit");
            Check(policy.Step(999999, false, true) == WatchdogAction::None, "late unauthorized force");
        });
        Case("natural exit before normal", [] {
            WatchdogPolicy policy(Valid());
            Check(policy.Step(10, true, false) == WatchdogAction::None, "quit after verified exit");
            Check(policy.Step(1000, false, true) == WatchdogAction::None, "exit proof lost");
        });
        Case("natural exit during grace", [] {
            WatchdogPolicy policy(Valid()); policy.Step(100, false, false);
            Check(policy.Step(130, true, false) == WatchdogAction::None, "force after late exit");
            Check(!policy.ForceIssued(), "late exit counted as force");
        });
        Case("late first poll still normal first", [] {
            WatchdogPolicy policy(Valid());
            Check(policy.Step(10000, false, false) == WatchdogAction::RequestNormal, "late poll skipped normal");
            Check(policy.Step(10029, false, false) == WatchdogAction::None, "late poll skipped grace");
            Check(policy.Step(10030, false, false) == WatchdogAction::ForceClose, "late poll force missing");
        });
        Case("deadline cannot reset", [] {
            WatchdogPolicy policy(Valid());
            for (std::uint64_t elapsed = 0; elapsed != 100; ++elapsed)
                Check(policy.Step(elapsed, false, false) == WatchdogAction::None, "activity changed deadline");
            Check(policy.Step(100, false, false) == WatchdogAction::RequestNormal, "activity reset deadline");
        });
        Case("regressing clock fails to normal", [] {
            WatchdogPolicy policy(Valid()); policy.Step(80, false, false);
            Check(policy.Step(50, false, false) == WatchdogAction::RequestNormal, "clock regression ignored");
            Check(policy.NormalAt() == 80, "clock regression shortened grace origin");
            Check(policy.Step(79, false, false) == WatchdogAction::None, "regression forced early");
            Check(policy.Step(109, false, false) == WatchdogAction::None, "regression skipped grace");
            Check(policy.Step(110, false, false) == WatchdogAction::ForceClose, "regression force absent");
        });
        Case("config copied", [] {
            auto config = Valid(false); WatchdogPolicy policy(config); config.forceCloseAuthorized = true;
            policy.Step(100, false, false);
            Check(policy.Step(130, false, false) == WatchdogAction::None, "mutable config granted authority");
        });
        std::cout << "PASS watchdog-policy cases=" << cases << " assertions=" << assertions << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL watchdog-policy: " << error.what() << '\n';
        return 1;
    }
}
