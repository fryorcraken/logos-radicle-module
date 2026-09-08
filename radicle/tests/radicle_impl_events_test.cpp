// Test-only forwarder bodies for RadicleImpl's `logos_events:` methods.
//
// Universal-module unit tests construct RadicleImpl directly (no Qt provider
// / LogosAPI), so the codegen-emitted `<name>_events.cpp` that normally
// implements these methods (marshalling through Qt) is never linked in here.
// Without bodies for remoteSeedChanged/localAvailabilityChanged, adding
// radicle_impl.cpp to the test binary fails to LINK (undefined reference),
// not to compile — see logos_test_events.h's doc comment for the pattern this
// follows: one-line forwarders to logos_test::recordEvent(), observed via
// logos_test::EventCapture.
#include <logos_test.h>

#include "radicle_impl.h"

void RadicleImpl::remoteSeedChanged(const std::string& seedUrl)
{
    logos_test::recordEvent("remoteSeedChanged", seedUrl);
}

void RadicleImpl::localAvailabilityChanged(const std::string& capabilitiesJson)
{
    logos_test::recordEvent("localAvailabilityChanged", capabilitiesJson);
}
