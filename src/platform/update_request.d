module platform.update_request;

// The update activity marker is writable by the telemetry identity. Privileged
// maintenance must not follow symlinks, open devices/FIFOs, or read unbounded data.
string readUpdateTimestampFile(string path) {
    char[33] buffer;
    version (Posix) {
        import core.sys.posix.fcntl : open, O_RDONLY, O_NOFOLLOW, O_NONBLOCK;
        import core.sys.posix.unistd : close, read;
        import core.sys.posix.sys.stat : fstat, stat_t, S_ISREG;
        import std.string : toStringz;
        auto fd = open(path.toStringz, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
        if (fd < 0) return "";
        scope(exit) close(fd);
        stat_t info;
        if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size > 32) return "";
        auto size = read(fd, buffer.ptr, buffer.length);
        if (size < 0 || size > 32) return "";
        return buffer[0 .. size].idup;
    } else version (Windows) {
        import core.sys.windows.windows;
        import std.utf : toUTF16z;
        auto file = CreateFileW(path.toUTF16z, GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null,
            OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, null);
        if (file == INVALID_HANDLE_VALUE) return "";
        scope(exit) CloseHandle(file);
        BY_HANDLE_FILE_INFORMATION info;
        if (GetFileType(file) != FILE_TYPE_DISK || !GetFileInformationByHandle(file, &info) ||
            (info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) ||
            info.nFileSizeHigh != 0 || info.nFileSizeLow > 32) return "";
        DWORD size;
        if (!ReadFile(file, buffer.ptr, cast(DWORD) buffer.length, &size, null) || size > 32) return "";
        return buffer[0 .. size].idup;
    } else return "";
}
