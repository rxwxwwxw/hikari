module platform.durable;

// POSIX activation ordering: persist data before switching a symlink, then
// persist its parent directory. These operations run only during maintenance.
void syncUpdatePath(string path, bool directory = false) {
    version (Posix) {
        import core.sys.posix.fcntl : open, O_RDONLY, O_NOFOLLOW;
        import core.sys.posix.unistd : close, fsync;
        import std.string : toStringz;
        auto fd = open(path.toStringz(), O_RDONLY | O_NOFOLLOW);
        if (fd < 0) throw new Exception("Unable to open update data for durability check");
        scope (exit) close(fd);
        if (fsync(fd) != 0) throw new Exception("Unable to persist update data");
        version (OSX) {
            import core.sys.posix.fcntl : fcntl;
            if (!directory && fcntl(fd, 51 /* F_FULLFSYNC */) != 0)
                throw new Exception("Unable to flush update data to storage");
        }
    }
}
