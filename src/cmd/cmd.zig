const std = @import("std");
const cli = @import("zig-cli");
const base58 = @import("base58-zig");
const dns = @import("zigdig");
const enumFromName = @import("../utils/types.zig").enumFromName;
const getOrInitIdentity = @import("./helpers.zig").getOrInitIdentity;
const ContactInfo = @import("../gossip/data.zig").ContactInfo;
const SOCKET_TAG_GOSSIP = @import("../gossip/data.zig").SOCKET_TAG_GOSSIP;
const Logger = @import("../trace/log.zig").Logger;
const Level = @import("../trace/level.zig").Level;
const io = std.io;
const Pubkey = @import("../core/pubkey.zig").Pubkey;
const SocketAddr = @import("../net/net.zig").SocketAddr;
const echo = @import("../net/echo.zig");
const GossipService = @import("../gossip/service.zig").GossipService;
const servePrometheus = @import("../prometheus/http.zig").servePrometheus;
const globalRegistry = @import("../prometheus/registry.zig").globalRegistry;
const Registry = @import("../prometheus/registry.zig").Registry;
const getWallclockMs = @import("../gossip/data.zig").getWallclockMs;
const IpAddr = @import("../lib.zig").net.IpAddr;

const SnapshotPaths = @import("../accountsdb/snapshots.zig").SnapshotPaths;
const parallelUnpackZstdTarBall = @import("../accountsdb/snapshots.zig").parallelUnpackZstdTarBall;
const AllSnapshotFields = @import("../accountsdb/snapshots.zig").AllSnapshotFields;
const AccountsDB = @import("../accountsdb/db.zig").AccountsDB;
const AccountsDBConfig = @import("../accountsdb/db.zig").AccountsDBConfig;
const GenesisConfig = @import("../accountsdb/genesis_config.zig").GenesisConfig;
const StatusCache = @import("../accountsdb/snapshots.zig").StatusCache;
const SnapshotFields = @import("../accountsdb/snapshots.zig").SnapshotFields;
const Bank = @import("../accountsdb/bank.zig").Bank;
const downloadSnapshotsFromGossip = @import("../accountsdb/download.zig").downloadSnapshotsFromGossip;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const gpa_allocator = gpa.allocator();
const base58Encoder = base58.Encoder.init(.{});

const gossip_host = struct {
    // TODO: support domain names and ipv6 addresses
    var option = cli.Option{
        .long_name = "gossip-host",
        .help = "IPv4 address for the validator to advertise in gossip - default: get from --entrypoint, fallback to 127.0.0.1",
        .value = cli.OptionValue{ .string = null },
        .required = false,
        .value_name = "Gossip Host",
    };

    fn get() !?IpAddr {
        if (option.value.string) |str| {
            var buf: [15]u8 = undefined;
            @memcpy(buf[0..str.len], str);
            @memcpy(buf[str.len .. str.len + 2], ":0");
            const sa = try SocketAddr.parseIpv4(buf[0 .. str.len + 2]);
            return .{ .ipv4 = sa.V4.ip };
        }
        return null;
    }
};

var gossip_port_option = cli.Option{
    .long_name = "gossip-port",
    .help = "The port to run gossip listener - default: 8001",
    .short_alias = 'p',
    .value = cli.OptionValue{ .int = 8001 },
    .required = false,
    .value_name = "Gossip Port",
};

var gossip_entrypoints_option = cli.Option{
    .long_name = "entrypoint",
    .help = "gossip address of the entrypoint validators",
    .short_alias = 'e',
    .value = cli.OptionValue{ .string_list = null },
    .required = false,
    .value_name = "Entrypoints",
};

var gossip_spy_node_option = cli.Option{
    .long_name = "spy-node",
    .help = "run as a gossip spy node (minimize outgoing packets)",
    .value = cli.OptionValue{ .bool = false },
    .required = false,
    .value_name = "Spy Node",
};

var gossip_dump_option = cli.Option{
    .long_name = "dump-gossip",
    .help = "periodically dump gossip table to csv files and logs",
    .value = cli.OptionValue{ .bool = false },
    .required = false,
    .value_name = "Gossip Table Dump",
};

var log_level_option = cli.Option{
    .long_name = "log-level",
    .help = "The amount of detail to log (default = debug)",
    .short_alias = 'l',
    .value = cli.OptionValue{ .string = "debug" },
    .required = false,
    .value_name = "err|warn|info|debug",
};

var metrics_port_option = cli.Option{
    .long_name = "metrics-port",
    .help = "port to expose prometheus metrics via http",
    .short_alias = 'm',
    .value = cli.OptionValue{ .int = 12345 },
    .required = false,
    .value_name = "port_number",
};

// accounts-db options
var n_threads_snapshot_load_option = cli.Option{
    .long_name = "n-threads-snapshot-load",
    .help = "number of threads to load incremental snapshots",
    .short_alias = 't',
    .value = cli.OptionValue{ .int = 0 },
    .required = false,
    .value_name = "n_threads_snapshot_load",
};

var n_threads_snapshot_unpack_option = cli.Option{
    .long_name = "n-threads-snapshot-unpack",
    .help = "number of threads to unpack incremental snapshots",
    .short_alias = 'u',
    .value = cli.OptionValue{ .int = 0 },
    .required = false,
    .value_name = "n_threads_snapshot_unpack",
};

var disk_index_path_option = cli.Option{
    .long_name = "disk-index-path",
    .help = "path to disk index",
    .short_alias = 'd',
    .value = cli.OptionValue{ .string = null },
    .required = false,
    .value_name = "disk_index_path",
};

var force_unpack_snapshot_option = cli.Option{
    .long_name = "force-unpack-snapshot",
    .help = "force unpack snapshot even if it exists",
    .short_alias = 'f',
    .value = cli.OptionValue{ .bool = false },
    .required = false,
    .value_name = "force_unpack_snapshot",
};

var snapshot_dir_option = cli.Option{
    .long_name = "snapshot-dir",
    .help = "path to snapshot directory",
    .short_alias = 's',
    .value = cli.OptionValue{ .string = "test_data/" },
    .required = false,
    .value_name = "snapshot_dir",
};

var app = &cli.App{
    .name = "sig",
    .description = "Sig is a Solana client implementation written in Zig.\nThis is still a WIP, PRs welcome.",
    .version = "0.1.1",
    .author = "Syndica & Contributors",
    .options = &.{ &log_level_option, &metrics_port_option },
    .subcommands = &.{
        &cli.Command{
            .name = "identity",
            .help = "Get own identity",
            .description =
            \\Gets own identity (Pubkey) or creates one if doesn't exist.
            \\
            \\NOTE: Keypair is saved in $HOME/.sig/identity.key.
            ,
            .action = identity,
        },
        &cli.Command{
            .name = "gossip",
            .help = "Run gossip client",
            .description =
            \\Start Solana gossip client on specified port.
            ,
            .action = gossip,
            .options = &.{
                &gossip_port_option,
                &gossip_entrypoints_option,
                &gossip_spy_node_option,
                &gossip_dump_option,
            },
        },
        &cli.Command{
            .name = "accounts_db",
            .help = "run accounts_db",
            .description =
            \\starts accounts db
            ,
            .action = accountsDb,
            .options = &.{
                &n_threads_snapshot_load_option,
                &n_threads_snapshot_unpack_option,
                &disk_index_path_option,
                &force_unpack_snapshot_option,
                &snapshot_dir_option,
            },
        },
    },
};

// prints (and creates if DNE) pubkey in ~/.sig/identity.key
fn identity(_: []const []const u8) !void {
    var logger = Logger.init(gpa_allocator, try enumFromName(Level, log_level_option.value.string.?));
    defer logger.deinit();
    logger.spawn();

    const keypair = try getOrInitIdentity(gpa_allocator, logger);
    var pubkey: [50]u8 = undefined;
    var size = try base58Encoder.encode(&keypair.public_key.toBytes(), &pubkey);
    try std.io.getStdErr().writer().print("Identity: {s}\n", .{pubkey[0..size]});
}

// gossip entrypoint
fn gossip(_: []const []const u8) !void {
    var logger = Logger.init(gpa_allocator, try enumFromName(Level, log_level_option.value.string.?));
    defer logger.deinit();
    logger.spawn();

    const metrics_thread = try spawnMetrics(gpa_allocator, logger);

    var my_keypair = try getOrInitIdentity(gpa_allocator, logger);

    var gossip_port: u16 = @intCast(gossip_port_option.value.int.?);
    logger.infof("gossip port: {d}", .{gossip_port});

    var entrypoints = std.ArrayList(SocketAddr).init(gpa_allocator);
    defer entrypoints.deinit();
    if (gossip_entrypoints_option.value.string_list) |entrypoints_strs| {
        for (entrypoints_strs) |entrypoint| {
            var socket_addr = SocketAddr.parse(entrypoint) catch brk: {
                // if we couldn't parse as IpV4, we attempt to resolve DNS and get IP
                var domain_and_port = std.mem.splitScalar(u8, entrypoint, ':');
                const domain_str = domain_and_port.next() orelse {
                    logger.field("entrypoint", entrypoint).err("entrypoint domain missing");
                    return error.EntrypointDomainMissing;
                };
                const port_str = domain_and_port.next() orelse {
                    logger.field("entrypoint", entrypoint).err("entrypoint port missing");
                    return error.EntrypointPortMissing;
                };

                // get dns address lists
                var addr_list = try dns.helpers.getAddressList(domain_str, gpa_allocator);
                defer addr_list.deinit();
                if (addr_list.addrs.len == 0) {
                    logger.field("entrypoint", entrypoint).err("entrypoint resolve dns failed (no records found)");
                    return error.EntrypointDnsResolutionFailure;
                }

                // use first A record address
                var ipv4_addr = addr_list.addrs[0];

                // parse port from string
                var port = std.fmt.parseInt(u16, port_str, 10) catch {
                    logger.field("entrypoint", entrypoint).err("entrypoint port not valid");
                    return error.EntrypointPortNotValid;
                };

                var socket_addr = SocketAddr.fromIpV4Address(ipv4_addr);
                socket_addr.setPort(port);
                break :brk socket_addr;
            };

            try entrypoints.append(socket_addr);
        }
    }

    // log entrypoints
    var entrypoint_string = try gpa_allocator.alloc(u8, 53 * entrypoints.items.len);
    defer gpa_allocator.free(entrypoint_string);
    var stream = std.io.fixedBufferStream(entrypoint_string);
    var writer = stream.writer();
    for (0.., entrypoints.items) |i, entrypoint| {
        try entrypoint.toAddress().format("", .{}, writer);
        if (i != entrypoints.items.len - 1) try writer.writeAll(", ");
    }
    logger.infof("entrypoints: {s}", .{entrypoint_string[0..stream.pos]});

    // determine our shred version and ip. in the solana-labs client, the shred version
    // comes from the snapshot, and ip echo is only used to validate it.
    var my_ip_from_entrypoint: ?IpAddr = null;
    const my_shred_version = loop: for (entrypoints.items) |entrypoint| {
        if (echo.requestIpEcho(gpa_allocator, entrypoint.toAddress(), .{})) |response| {
            if (my_ip_from_entrypoint == null) my_ip_from_entrypoint = response.address;
            if (response.shred_version) |shred_version| {
                var addr_str = entrypoint.toString();
                logger.infof(
                    "shred version: {} - from entrypoint ip echo: {s}",
                    .{ shred_version.value, addr_str[0][0..addr_str[1]] },
                );
                break shred_version.value;
            }
        } else |_| {}
    } else {
        logger.warn("could not get a shred version from an entrypoint");
        break :loop 0;
    };
    const my_ip = try gossip_host.get() orelse my_ip_from_entrypoint orelse IpAddr.newIpv4(127, 0, 0, 1);
    logger.infof("my ip: {}", .{my_ip});

    // setup contact info
    var my_pubkey = Pubkey.fromPublicKey(&my_keypair.public_key);
    var contact_info = ContactInfo.init(gpa_allocator, my_pubkey, getWallclockMs(), 0);
    contact_info.shred_version = my_shred_version;
    var gossip_address = SocketAddr.init(my_ip, gossip_port);
    try contact_info.setSocket(SOCKET_TAG_GOSSIP, gossip_address);

    var exit = std.atomic.Atomic(bool).init(false);
    var gossip_service = try GossipService.init(
        gpa_allocator,
        contact_info,
        my_keypair,
        entrypoints,
        &exit,
        logger,
    );
    defer gossip_service.deinit();

    const spy_node = gossip_spy_node_option.value.bool;
    var handle = try std.Thread.spawn(
        .{},
        GossipService.run,
        .{ &gossip_service, spy_node, gossip_dump_option.value.bool },
    );

    try downloadSnapshotsFromGossip(gpa_allocator, &gossip_service);

    handle.join();
    metrics_thread.detach();
}

/// Initializes the global registry. Returns error if registry was already initialized.
/// Spawns a thread to serve the metrics over http on the CLI configured port.
/// Uses same allocator for both registry and http adapter.
fn spawnMetrics(allocator: std.mem.Allocator, logger: Logger) !std.Thread {
    var metrics_port: u16 = @intCast(metrics_port_option.value.int.?);
    logger.infof("metrics port: {d}", .{metrics_port});
    const registry = globalRegistry();
    return try std.Thread.spawn(.{}, servePrometheus, .{ allocator, registry, metrics_port });
}

fn accountsDb(_: []const []const u8) !void {
    var allocator = gpa.allocator();

    var logger = Logger.init(gpa_allocator, try enumFromName(Level, log_level_option.value.string.?));
    defer logger.deinit();
    logger.spawn();

    // arg parsing
    const disk_index_path: ?[]const u8 = disk_index_path_option.value.string;
    const force_unpack_snapshot = force_unpack_snapshot_option.value.bool;
    const snapshot_dir = snapshot_dir_option.value.string.?;

    const n_cpus = @as(u32, @truncate(try std.Thread.getCpuCount()));
    var n_threads_snapshot_load: u32 = @intCast(n_threads_snapshot_load_option.value.int.?);
    if (n_threads_snapshot_load == 0) {
        n_threads_snapshot_load = n_cpus;
    }

    var n_threads_snapshot_unpack: u32 = @intCast(n_threads_snapshot_load_option.value.int.?);
    if (n_threads_snapshot_unpack == 0) {
        n_threads_snapshot_unpack = n_cpus * 2;
    }

    // this should exist before we start to unpack
    const genesis_path = try std.fmt.allocPrint(
        allocator,
        "{s}/genesis.bin",
        .{snapshot_dir},
    );
    defer allocator.free(genesis_path);

    std.fs.cwd().access(genesis_path, .{}) catch {
        logger.errf("genesis.bin not found: {s}", .{genesis_path});
        return error.GenesisNotFound;
    };

    // if this exists, we wont look for a .tar.zstd
    const accounts_path = try std.fmt.allocPrint(
        allocator,
        "{s}/accounts/",
        .{snapshot_dir},
    );
    defer allocator.free(accounts_path);

    var accounts_path_exists = true;
    std.fs.cwd().access(accounts_path, .{}) catch {
        accounts_path_exists = false;
    };
    const should_unpack_snapshot = !accounts_path_exists or force_unpack_snapshot;

    var snapshot_paths = try SnapshotPaths.find(allocator, snapshot_dir);
    if (snapshot_paths.incremental_snapshot == null) {
        logger.infof("no incremental snapshot found", .{});
    }

    var full_timer = try std.time.Timer.start();
    var timer = try std.time.Timer.start();

    if (should_unpack_snapshot) {
        logger.infof("unpacking snapshots...", .{});
        // if accounts/ doesnt exist then we unpack the found snapshots
        var snapshot_dir_iter = try std.fs.cwd().openIterableDir(snapshot_dir, .{});
        defer snapshot_dir_iter.close();

        // TODO: delete old accounts/ dir if it exists

        timer.reset();
        std.debug.print("unpacking {s}...", .{snapshot_paths.full_snapshot.path});
        logger.infof("unpacking {s}...", .{snapshot_paths.full_snapshot.path});
        try parallelUnpackZstdTarBall(
            allocator,
            snapshot_paths.full_snapshot.path,
            snapshot_dir_iter.dir,
            n_threads_snapshot_unpack,
            true,
        );
        logger.infof("unpacked snapshot in {s}", .{std.fmt.fmtDuration(timer.read())});

        // TODO: can probs do this in parallel with full snapshot
        if (snapshot_paths.incremental_snapshot) |incremental_snapshot| {
            timer.reset();
            logger.infof("unpacking {s}...", .{incremental_snapshot.path});
            try parallelUnpackZstdTarBall(
                allocator,
                incremental_snapshot.path,
                snapshot_dir_iter.dir,
                n_threads_snapshot_unpack,
                false,
            );
            logger.infof("unpacked snapshot in {s}", .{std.fmt.fmtDuration(timer.read())});
        }
    } else {
        logger.infof("not unpacking snapshot...", .{});
    }

    timer.reset();
    logger.infof("reading snapshot metadata...", .{});
    var snapshots = try AllSnapshotFields.fromPaths(allocator, snapshot_dir, snapshot_paths);
    defer {
        snapshots.all_fields.deinit(allocator);
        allocator.free(snapshots.full_path);
        if (snapshots.incremental_path) |inc_path| {
            allocator.free(inc_path);
        }
    }
    logger.infof("read snapshot metdata in {s}", .{std.fmt.fmtDuration(timer.read())});
    const full_snapshot = snapshots.all_fields.full;

    logger.infof("full snapshot: {s}", .{snapshots.full_path});
    if (snapshots.incremental_path) |inc_path| {
        logger.infof("incremental snapshot: {s}", .{inc_path});
    }

    // load and validate
    logger.infof("initializing accounts-db...", .{});
    var accounts_db = try AccountsDB.init(allocator, logger, AccountsDBConfig{
        .disk_index_path = disk_index_path,
        .storage_cache_size = 10_000,
    });
    defer accounts_db.deinit();
    logger.infof("initialized in {s}", .{std.fmt.fmtDuration(timer.read())});
    timer.reset();

    const snapshot = try snapshots.all_fields.collapse();
    timer.reset();

    logger.infof("loading from snapshot...", .{});
    try accounts_db.loadFromSnapshot(
        snapshot.accounts_db_fields,
        accounts_path,
        n_threads_snapshot_load,
        std.heap.page_allocator,
    );
    logger.infof("loaded from snapshot in {s}", .{std.fmt.fmtDuration(timer.read())});

    try accounts_db.validateLoadFromSnapshot(
        snapshot.bank_fields.incremental_snapshot_persistence,
        full_snapshot.bank_fields.slot,
        full_snapshot.bank_fields.capitalization,
    );
    logger.infof("validated from snapshot in {s}", .{std.fmt.fmtDuration(timer.read())});
    logger.infof("full timer: {s}", .{std.fmt.fmtDuration(full_timer.read())});

    // use the genesis to validate the bank
    const genesis_config = try GenesisConfig.init(allocator, genesis_path);
    defer genesis_config.deinit(allocator);

    logger.infof("validating bank...", .{});
    const bank = Bank.init(&accounts_db, &snapshot.bank_fields);
    try Bank.validateBankFields(bank.bank_fields, &genesis_config);

    // validate the status cache
    logger.infof("validating status cache...", .{});
    const status_cache_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ snapshot_dir, "snapshots/status_cache" },
    );
    defer allocator.free(status_cache_path);

    var status_cache = try StatusCache.init(allocator, status_cache_path);
    defer status_cache.deinit();

    var slot_history = try accounts_db.getSlotHistory();
    defer slot_history.deinit(accounts_db.allocator);

    const bank_slot = snapshot.bank_fields.slot;
    try status_cache.validate(allocator, bank_slot, &slot_history);

    logger.infof("done!", .{});
}

pub fn run() !void {
    return cli.run(app, gpa_allocator);
}
