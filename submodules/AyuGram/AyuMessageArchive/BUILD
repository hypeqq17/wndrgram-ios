load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "AyuMessageArchive",
    module_name = "AyuMessageArchive",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/Postbox:Postbox",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AyuGram/AyuSettings:AyuSettings",
    ],
    visibility = [
        "//visibility:public",
    ],
)
