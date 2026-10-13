#pragma once
#include "startup_contract.h"
#include "device_observer.h"
#include "entry_contract.h"
#include "import_observer.h"
#include "pipeline_audit.h"
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
struct BeamRTEntryFixtureReport {
    BeamRTStartupFixtureReport startup;
    BeamRTEntryStatus entry;
    BeamRTDeviceObservation device;
    uint32_t frameMatches,preMainReached,warp,mode;
};
static_assert(sizeof(BeamRTEntryFixtureReport)==240,"entry fixture report layout");
struct BeamRTImportFixtureReport {
    BeamRTStartupFixtureReport startup;
    BeamRTImportObservation beforeDisable,afterDisable;
    uint32_t testsMask,guardsRejected,warp,reserved;
};
static_assert(sizeof(BeamRTImportFixtureReport)==320,"import fixture report layout");
struct BeamRTPipelineFixtureReport {
    BeamRTStartupFixtureReport startup;BeamRTPipelineAuditInfo audit;
    uint32_t ownerMatches,rootBytes,matched,reserved;
    uint8_t rootDigest[32];
};
