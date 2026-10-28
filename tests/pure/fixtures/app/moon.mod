// Root and test/bridge both require test/lib 2.0.0, so one copy is shared.
name = "test/app"
version = "0.1.0"
import { "test/lib@2.0.0", "test/bridge@1.0.0" }
options(source: "src")
supported_targets = "all - native + native"
