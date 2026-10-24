import Foundation

// The engine's tests. Run them with scripts/test-mac.sh [part of a test name].

// What the engine stores goes to a temporary folder, never the real one.
setenv("DATA_DIR", join(testRoot, "data"), 1)
// Names are never looked up on the real TVmaze (tests that need it run their own).
setenv("TVMAZE_API", "http://127.0.0.1:9", 1)
// A peer closing a connection must not end the run.
signal(SIGPIPE, SIG_IGN)

let tests = Tests()
fingerprintTests(tests)
scannerTests(tests)
subSyncTests(tests)
subtitlesTests(tests)
madeSubsTests(tests)
namesTests(tests)
stillsTests(tests)
trickplayTests(tests)
let ok = await tests.run(filter: CommandLine.arguments.dropFirst().first)
removeItem(testRoot)
exit(ok ? 0 : 1)
