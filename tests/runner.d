module tests.runner;

import std.stdio : writeln;

// Imports test modules so all `unittest` blocks are compiled and executed by `dub test`.
import tests.core.test_tracker;
import tests.core.test_cache_coordinator;
import tests.core.test_config_serializer;
import tests.core.test_log;
import tests.platform.test_linux_parsers;
import tests.platform.test_hardware_isa;
import tests.platform.test_cross_platform;
import tests.platform.test_darwin;
import tests.platform.test_windows_parsers;
import tests.platform.test_winservice;
import tests.http.test_http_tailnet;
import tests.update.test_update_lifecycle;

void main() {
    writeln("All hikari D unit and contract test suites passed.");
}
