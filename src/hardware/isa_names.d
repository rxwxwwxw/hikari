module hardware.isa_names;

import std.algorithm : sort, uniq;
import std.array : array;
import std.string : toLower;

enum IsaCategory : string {
    vector_simd = "Vector/SIMD",
    cryptography = "Cryptography",
    bit_manipulation = "Bit manipulation",
    virtualization = "Virtualization",
    other = "Other",
}

struct IsaFeatureMeta {
    string id;
    string label;
    IsaCategory category;
    string description;
}

immutable IsaFeatureMeta[string] ISA_CATALOG;

shared static this() {
    ISA_CATALOG = [
        // x86 / x86-64 Vector/SIMD
        "sse": IsaFeatureMeta("sse", "SSE", IsaCategory.vector_simd, "Streaming SIMD Extensions (128-bit single-precision floating point)"),
        "sse2": IsaFeatureMeta("sse2", "SSE2", IsaCategory.vector_simd, "Baseline x86-64 128-bit integer and double-precision SIMD"),
        "sse3": IsaFeatureMeta("sse3", "SSE3", IsaCategory.vector_simd, "Horizontal vector arithmetic and thread synchronization helpers"),
        "ssse3": IsaFeatureMeta("ssse3", "SSSE3", IsaCategory.vector_simd, "Supplemental SSE3 byte-shuffling and fused multiply-add helpers"),
        "sse4_1": IsaFeatureMeta("sse4_1", "SSE4.1", IsaCategory.vector_simd, "Dot products, vector blending, and integer min/max operations"),
        "sse4_2": IsaFeatureMeta("sse4_2", "SSE4.2", IsaCategory.vector_simd, "Hardware CRC32C and string/text processing instructions"),
        "avx": IsaFeatureMeta("avx", "AVX", IsaCategory.vector_simd, "Advanced Vector Extensions (256-bit floating-point SIMD; requires OS XSAVE)"),
        "avx2": IsaFeatureMeta("avx2", "AVX2", IsaCategory.vector_simd, "256-bit integer SIMD, gather loads, and broad vector shifts"),
        "fma": IsaFeatureMeta("fma", "FMA3", IsaCategory.vector_simd, "Fused multiply-add with single rounding on 128/256-bit vectors"),
        "f16c": IsaFeatureMeta("f16c", "F16C", IsaCategory.vector_simd, "Hardware half-precision (FP16) vector conversion instructions"),
        "avx512f": IsaFeatureMeta("avx512f", "AVX-512F", IsaCategory.vector_simd, "AVX-512 Foundation 512-bit vector operations (requires OS ZMM XSAVE)"),
        "avx512dq": IsaFeatureMeta("avx512dq", "AVX-512DQ", IsaCategory.vector_simd, "AVX-512 doubleword and quadword vector instructions"),
        "avx512bw": IsaFeatureMeta("avx512bw", "AVX-512BW", IsaCategory.vector_simd, "AVX-512 byte and word 512-bit vector instructions"),
        "avx512vl": IsaFeatureMeta("avx512vl", "AVX-512VL", IsaCategory.vector_simd, "AVX-512 masking and extended registers on 128/256-bit vectors"),
        "avx512cd": IsaFeatureMeta("avx512cd", "AVX-512CD", IsaCategory.vector_simd, "AVX-512 conflict detection for vectorizing loops"),
        "avx512vnni": IsaFeatureMeta("avx512vnni", "AVX-512 VNNI", IsaCategory.vector_simd, "Vector Neural Network Instructions for INT8 dot-product inference"),
        "avx512bf16": IsaFeatureMeta("avx512bf16", "AVX-512 BF16", IsaCategory.vector_simd, "BFloat16 vector conversion and dot-product instructions"),
        "avx_vnni": IsaFeatureMeta("avx_vnni", "AVX-VNNI", IsaCategory.vector_simd, "256-bit Vector Neural Network Instructions without AVX-512"),

        // x86 Cryptography
        "aes": IsaFeatureMeta("aes", "AES-NI", IsaCategory.cryptography, "Hardware-accelerated AES encryption and decryption rounds"),
        "pclmulqdq": IsaFeatureMeta("pclmulqdq", "PCLMULQDQ", IsaCategory.cryptography, "Carry-less multiplication for GCM authentication and CRC"),
        "vaes": IsaFeatureMeta("vaes", "VAES", IsaCategory.cryptography, "Vectorized 256/512-bit AES instructions"),
        "vpclmulqdq": IsaFeatureMeta("vpclmulqdq", "VPCLMULQDQ", IsaCategory.cryptography, "Vectorized 256/512-bit carry-less multiplication"),
        "sha": IsaFeatureMeta("sha", "SHA-NI", IsaCategory.cryptography, "Hardware acceleration for SHA-1 and SHA-256"),
        "rdrand": IsaFeatureMeta("rdrand", "RDRAND", IsaCategory.cryptography, "Hardware random number generator instruction"),
        "rdseed": IsaFeatureMeta("rdseed", "RDSEED", IsaCategory.cryptography, "Cryptographic entropy seed instruction"),

        // x86 Bit manipulation
        "bmi1": IsaFeatureMeta("bmi1", "BMI1", IsaCategory.bit_manipulation, "Bit Manipulation Instruction Set 1 (TZCNT, ANDN, BEXTR)"),
        "bmi2": IsaFeatureMeta("bmi2", "BMI2", IsaCategory.bit_manipulation, "Bit Manipulation Instruction Set 2 (PDEP, PEXT, MULX, RORX)"),
        "adx": IsaFeatureMeta("adx", "ADX", IsaCategory.bit_manipulation, "Multi-precision carry-chain integer arithmetic (ADCX, ADOX)"),
        "popcnt": IsaFeatureMeta("popcnt", "POPCNT", IsaCategory.bit_manipulation, "Hardware population count (number of set bits)"),
        "lzcnt": IsaFeatureMeta("lzcnt", "LZCNT/ABM", IsaCategory.bit_manipulation, "Leading-zero bit count instruction"),
        "movbe": IsaFeatureMeta("movbe", "MOVBE", IsaCategory.bit_manipulation, "Byte-swap move for endian conversions"),

        // x86 Virtualization & Other
        "vmx": IsaFeatureMeta("vmx", "Intel VT-x (VMX)", IsaCategory.virtualization, "Intel hardware-assisted virtualization extensions"),
        "svm": IsaFeatureMeta("svm", "AMD-V (SVM)", IsaCategory.virtualization, "AMD Secure Virtual Machine hardware virtualization"),
        "xsave": IsaFeatureMeta("xsave", "XSAVE", IsaCategory.other, "OS-managed extended processor state save/restore"),
        "osxsave": IsaFeatureMeta("osxsave", "OSXSAVE", IsaCategory.other, "OS has enabled XSAVE/XCR0 extended register management"),
        "cmpxchg16b": IsaFeatureMeta("cmpxchg16b", "CMPXCHG16B", IsaCategory.other, "128-bit atomic compare-and-exchange"),
        "fsgsbase": IsaFeatureMeta("fsgsbase", "FSGSBASE", IsaCategory.other, "User-space fast FS/GS segment base access"),

        // ARM64 / AArch64
        "fp": IsaFeatureMeta("fp", "FP", IsaCategory.vector_simd, "ARM64 hardware IEEE-754 floating-point arithmetic"),
        "asimd": IsaFeatureMeta("asimd", "NEON (ASIMD)", IsaCategory.vector_simd, "ARM64 128-bit Advanced SIMD vector instructions"),
        "fphp": IsaFeatureMeta("fphp", "FP16", IsaCategory.vector_simd, "ARM64 scalar half-precision floating point"),
        "asimdhp": IsaFeatureMeta("asimdhp", "NEON FP16", IsaCategory.vector_simd, "ARM64 vector half-precision floating point"),
        "asimddp": IsaFeatureMeta("asimddp", "DotProd", IsaCategory.vector_simd, "ARM64 8-bit integer vector dot-product acceleration"),
        "sve": IsaFeatureMeta("sve", "SVE", IsaCategory.vector_simd, "Scalable Vector Extension for variable-width SIMD"),
        "sve2": IsaFeatureMeta("sve2", "SVE2", IsaCategory.vector_simd, "Scalable Vector Extension version 2"),
        "bf16": IsaFeatureMeta("bf16", "BF16", IsaCategory.vector_simd, "ARM64 BFloat16 matrix and vector instructions"),
        "i8mm": IsaFeatureMeta("i8mm", "I8MM", IsaCategory.vector_simd, "ARM64 Int8 matrix multiplication instructions"),
        "pmull": IsaFeatureMeta("pmull", "PMULL", IsaCategory.cryptography, "ARM64 64x64->128-bit polynomial multiplication for GCM"),
        "sha1": IsaFeatureMeta("sha1", "SHA1", IsaCategory.cryptography, "ARM64 hardware SHA-1 instructions"),
        "sha2": IsaFeatureMeta("sha2", "SHA256", IsaCategory.cryptography, "ARM64 hardware SHA-256 instructions"),
        "sha3": IsaFeatureMeta("sha3", "SHA3", IsaCategory.cryptography, "ARM64 hardware SHA-3 instructions"),
        "sha512": IsaFeatureMeta("sha512", "SHA512", IsaCategory.cryptography, "ARM64 hardware SHA-512 instructions"),
        "sm3": IsaFeatureMeta("sm3", "SM3", IsaCategory.cryptography, "ARM64 hardware SM3 hash instructions"),
        "sm4": IsaFeatureMeta("sm4", "SM4", IsaCategory.cryptography, "ARM64 hardware SM4 cipher instructions"),
        "rng": IsaFeatureMeta("rng", "RNDR", IsaCategory.cryptography, "ARM64 hardware random number generator"),
        "crc32": IsaFeatureMeta("crc32", "CRC32", IsaCategory.bit_manipulation, "ARM64 hardware CRC32/CRC32C checksum instructions"),
        "atomics": IsaFeatureMeta("atomics", "LSE Atomics", IsaCategory.other, "Large System Extensions single-instruction atomic primitives"),
        "jscvt": IsaFeatureMeta("jscvt", "JSCVT", IsaCategory.other, "JavaScript double-to-int32 conversion instruction"),
        "fcma": IsaFeatureMeta("fcma", "FCMA", IsaCategory.vector_simd, "Floating-point complex number multiply-add"),
        "bti": IsaFeatureMeta("bti", "BTI", IsaCategory.other, "Branch Target Identification control-flow security"),
        "paca": IsaFeatureMeta("paca", "PAuth", IsaCategory.other, "Pointer Authentication instructions"),
    ];
}

string normalizeIsaFlag(string raw) pure @safe {
    auto f = raw.toLower();
    switch (f) {
        case "sse4_1":
        case "sse4.1":
            return "sse4_1";
        case "sse4_2":
        case "sse4.2":
            return "sse4_2";
        case "pclmulqdq":
        case "pclmul":
            return "pclmulqdq";
        case "sha_ni":
        case "sha":
            return "sha";
        case "abm":
        case "lzcnt":
            return "lzcnt";
        case "cx16":
        case "cmpxchg16b":
            return "cmpxchg16b";
        case "neon":
        case "asimd":
            return "asimd";
        case "evtstrm":
            return ""; // OS event stream timer, not an instruction set extension
        case "cpuid":
            return "";
        default:
            if (f in ISA_CATALOG) return f;
            return "";
    }
}

string[] normalizeIsaList(const string[] rawFlags) pure @safe {
    string[] res;
    foreach (r; rawFlags) {
        auto norm = normalizeIsaFlag(r);
        if (norm.length > 0) res ~= norm;
    }
    res.sort();
    return res.uniq().array;
}

IsaFeatureMeta describeIsaFeature(string canonicalId) pure nothrow @safe {
    if (auto p = canonicalId in ISA_CATALOG) return *p;
    return IsaFeatureMeta(canonicalId, canonicalId, IsaCategory.other, "Processor instruction-set feature");
}
