#pragma once
#include "startup_contract.h"
#include "device_observer.h"
// Reports written by the disposable fixture AFTER loader initialization.
struct BeamRTStartupFixtureReport {
    uint32_t bytes,magic,queryOK,initialThread,cwdMatches,argsMatch,processId,reserved;
    BeamRTStartupStatus status;
};
static_assert(sizeof(BeamRTStartupFixtureReport)==64,"fixture report layout");
inline constexpr uint32_t beamrtStartupFixtureMagic=0x42524658;
struct BeamRTDeviceFixtureReport {
    BeamRTStartupFixtureReport startup;
    uint32_t testsMask,guardsRejected,errorStep,warp;
    BeamRTDeviceObservation observation;
};
static_assert(sizeof(BeamRTDeviceFixtureReport)==176,"device fixture report layout");
