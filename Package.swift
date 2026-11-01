// swift-tools-version: 6.0
import PackageDescription

// 与 macOS/Metal 无关的 ggml 后端（CMake 按需编译，SPM 下手动排除）
let excludedBackends = [
    "ggml/ggml-blas", "ggml/ggml-cann", "ggml/ggml-cuda", "ggml/ggml-et",
    "ggml/ggml-hexagon", "ggml/ggml-hip", "ggml/ggml-musa", "ggml/ggml-opencl",
    "ggml/ggml-openvino", "ggml/ggml-rpc", "ggml/ggml-sycl", "ggml/ggml-virtgpu",
    "ggml/ggml-vulkan", "ggml/ggml-webgpu", "ggml/ggml-zdnn", "ggml/ggml-zendnn",
    "ggml/ggml-cpu/kleidiai", "ggml/ggml-cpu/amx", "ggml/ggml-cpu/spacemit",
    // CPU arch 变体互相定义同名符号，CMake 只选一个；arm64 上保留 arm，排除其余
    "ggml/ggml-cpu/arch/loongarch", "ggml/ggml-cpu/arch/powerpc", "ggml/ggml-cpu/arch/riscv",
    "ggml/ggml-cpu/arch/s390", "ggml/ggml-cpu/arch/wasm", "ggml/ggml-cpu/arch/x86",
    // Metal kernel 源不进编译：vendor 脚本已预编译为 Resources/default.metallib（随资源分发）
    "ggml/ggml-metal/kernels",
    // 可选硬件后端（CoreML / OpenVINO / VitisAI）需要对应 SDK，默认不编译
    // （aneforge/ANE 不排除：whisper.cpp 无条件引用其符号，实现内部是运行时 dlopen）
    "src/coreml", "src/openvino", "src/vitisai",
    // Parakeet 是另一套 ASR 架构（CMake 注入版本宏），本应用只用 Whisper
    "src/parakeet.cpp", "src/parakeet-arch.h",
]

let package = Package(
    name: "SubNow",
    platforms: [.macOS(.v14)],
    targets: [
        // whisper.cpp + ggml（C/C++/ObjC 混编，Metal 加速）
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            exclude: excludedBackends,
            resources: [
                .copy("Resources/default.metallib"),
                .copy("Resources/kernels"),
                .copy("Resources/ggml-common.h"),
                .copy("Resources/ggml-metal-impl.h"),
            ],
            cSettings: [
                .define("GGML_USE_METAL"),
                .define("GGML_USE_CPU"),
                .headerSearchPath("src"),
                .headerSearchPath("ggml"),
                .headerSearchPath("ggml/ggml-cpu"),
                .headerSearchPath("ggml/ggml-metal"),
                // ggml-metal 的 .m 是 MRC 手写内存管理，必须关 ARC（与上游 CMake 一致）
                .unsafeFlags(["-fno-objc-arc"]),
            ],
            cxxSettings: [
                .define("GGML_USE_METAL"),
                .define("GGML_USE_CPU"),
                .define("WHISPER_VERSION", to: "\"1.9.5\""),
                .headerSearchPath("src"),
                .headerSearchPath("ggml"),
                .headerSearchPath("ggml/ggml-cpu"),
                .headerSearchPath("ggml/ggml-metal"),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate"),
                .linkedLibrary("c++"),
            ]
        ),
        // 纯 C 桥：Swift 只面对这个稳定的 C API，隔离 whisper.cpp 的 C++ 细节
        .target(
            name: "WhisperBridge",
            dependencies: ["CWhisper"],
            path: "Sources/WhisperBridge",
            linkerSettings: [.linkedLibrary("c++")]
        ),
        // 主程序（菜单栏 App）
        .executableTarget(
            name: "SubNow",
            dependencies: ["WhisperBridge"],
            path: "Sources/SubNow",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SubNowTests",
            dependencies: ["SubNow"],
            path: "Tests/SubNowTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
