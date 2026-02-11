const std = @import("std");
const posix = std.posix;
const net = std.net;
const Connection = @import("connection.zig").Connection;

/// 풀링된 연결 정보
const PooledConnection = struct {
    conn: Connection,
    last_used_ms: i64,
};

/// 백엔드 연결 풀
/// Lazy Pooling: 사용된 keep-alive 연결만 저장 후 재사용
pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    /// 서버별 연결 리스트: "host:port" -> ArrayList(PooledConnection)
    pools: std.StringHashMap(std.ArrayList(PooledConnection)),
    /// 서버당 최대 연결 수
    max_per_server: usize,
    /// idle 타임아웃 (ms)
    idle_timeout_ms: i64,

    pub fn init(allocator: std.mem.Allocator) ConnectionPool {
        return ConnectionPool{
            .allocator = allocator,
            .pools = std.StringHashMap(std.ArrayList(PooledConnection)).init(allocator),
            .max_per_server = 10,
            .idle_timeout_ms = 30_000,
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        var iter = self.pools.iterator();
        while (iter.next()) |entry| {
            // 모든 연결 닫기
            for (entry.value_ptr.items) |*pooled| {
                pooled.conn.close();
            }
            entry.value_ptr.deinit(self.allocator);
            // key는 allocator로 할당되었으므로 해제
            self.allocator.free(entry.key_ptr.*);
        }
        self.pools.deinit();
    }

    /// 서버 키 생성: "host:port"
    fn makeKey(self: *ConnectionPool, host: []const u8, port: u16) ![]u8 {
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ host, port });
        return key;
    }

    /// 풀에서 연결 가져오기 (없으면 null)
    pub fn acquire(self: *ConnectionPool, host: []const u8, port: u16) ?Connection {
        const key = self.makeKey(host, port) catch return null;
        defer self.allocator.free(key);

        if (self.pools.getPtr(key)) |list| {
            const now = std.time.milliTimestamp();

            // 뒤에서부터 검사 (최근 사용된 것 우선)
            while (list.items.len > 0) {
                const pooled = list.pop() orelse break;

                // idle timeout 체크
                if (now - pooled.last_used_ms > self.idle_timeout_ms) {
                    // 만료됨, 닫고 다음 확인
                    var conn = pooled.conn;
                    conn.close();
                    continue;
                }

                std.debug.print("[Pool] ✅ Reused connection fd={} for {s}:{}\n", .{ pooled.conn.fd, host, port });
                // 유효한 연결 반환
                return pooled.conn;
            }
        }

        return null;
    }

    /// 연결을 풀에 반환
    pub fn release(self: *ConnectionPool, host: []const u8, port: u16, conn: Connection) void {
        const key = self.makeKey(host, port) catch {
            // 키 생성 실패 시 그냥 닫음
            var c = conn;
            c.close();
            return;
        };

        // 기존 엔트리 확인
        if (self.pools.getPtr(key)) |list| {
            self.allocator.free(key); // 이미 있으므로 새 키 해제

            // 최대 개수 체크
            if (list.items.len >= self.max_per_server) {
                // 가장 오래된 연결 제거
                if (list.items.len > 0) {
                    var oldest = list.orderedRemove(0);
                    oldest.conn.close();
                }
            }

            std.debug.print("[Pool] 📦 Stored connection fd={} for {s}:{}\n", .{ conn.fd, host, port });

            list.append(self.allocator, PooledConnection{
                .conn = conn,
                .last_used_ms = std.time.milliTimestamp(),
            }) catch {
                var c = conn;
                c.close();
            };
        } else {
            // 새 엔트리 생성
            var list = std.ArrayList(PooledConnection){};
            list.append(self.allocator, PooledConnection{
                .conn = conn,
                .last_used_ms = std.time.milliTimestamp(),
            }) catch {
                var c = conn;
                c.close();
                self.allocator.free(key);
                return;
            };

            self.pools.put(key, list) catch {
                for (list.items) |*p| {
                    p.conn.close();
                }
                list.deinit(self.allocator);
                self.allocator.free(key);
            };
        }
    }

    /// 만료된 연결 정리 (주기적 호출용)
    pub fn cleanupExpired(self: *ConnectionPool) void {
        const now = std.time.milliTimestamp();

        var iter = self.pools.iterator();
        while (iter.next()) |entry| {
            var list = entry.value_ptr;
            var i: usize = 0;

            while (i < list.items.len) {
                if (now - list.items[i].last_used_ms > self.idle_timeout_ms) {
                    var removed = list.orderedRemove(i);
                    removed.conn.close();
                    // i는 증가시키지 않음 (다음 요소가 현재 위치로 이동)
                } else {
                    i += 1;
                }
            }
        }
    }

    /// 디버그: 현재 풀 상태 출력
    pub fn debugPrint(self: *ConnectionPool) void {
        const stdout = std.io.getStdOut().writer();
        stdout.print("[ConnectionPool] Status:\n", .{}) catch {};

        var iter = self.pools.iterator();
        while (iter.next()) |entry| {
            stdout.print("  {s}: {} connections\n", .{ entry.key_ptr.*, entry.value_ptr.items.len }) catch {};
        }
    }
};
