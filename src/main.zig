const r4os = @import("r4os");

const service_name = "R4SLSVC";
const selftest_arg = "/SELFTEST";
const ping_arg = "/PING";
const service_timeout_ms: u64 = 1000;

const MAGIC: [4]u8 = .{ 'R', '4', 'S', 'L' };
const VERSION: u8 = 1;
const TYPE_DIAG: u8 = 1;
const TYPE_MESSAGE: u8 = 2;
const HEADER_SIZE: usize = 10;
const MAX_PAYLOAD: usize = r4os.abi.serial_link_payload_max;
const MAX_FRAME: usize = HEADER_SIZE + MAX_PAYLOAD;
const QUEUE_CAPACITY: usize = 4;

const QueueItem = struct {
    len: u16 = 0,
    data: [MAX_PAYLOAD]u8 = .{0} ** MAX_PAYLOAD,
};

const ServiceState = struct {
    requests: u64 = 0,
    status_requests: u64 = 0,
    poll_requests: u64 = 0,
    send_requests: u64 = 0,
    read_requests: u64 = 0,
    self_tests: u64 = 0,
    host_tests: u64 = 0,
    bad_ops: u64 = 0,
    queue_clears: u64 = 0,
    drops: u64 = 0,
    cancelled: u64 = 0,
    last_result: i32 = r4os.abi.serial_link_result_failed,
    last_kernel_message_rx: u64 = 0,
    kernel: r4os.abi.SerialLinkStatus = .{},
    inbox: [QUEUE_CAPACITY]QueueItem = .{QueueItem{}} ** QUEUE_CAPACITY,
    outbox: [QUEUE_CAPACITY]QueueItem = .{QueueItem{}} ** QUEUE_CAPACITY,
    inbox_count: u16 = 0,
    outbox_count: u16 = 0,
    last_service_message_len: u16 = 0,
    last_service_message: [MAX_PAYLOAD]u8 = .{0} ** MAX_PAYLOAD,
    last_error: [32]u8 = .{0} ** 32,
};

const App = struct {
    sys: r4os.r4sys.Context,
    net: r4os.r4net.Context,

    fn init(r4_app: *r4os.App) ?App {
        return .{
            .sys = r4_app.system(),
            .net = r4_app.networkLowLevel() orelse return null,
        };
    }
};

// Non-zero initializers keep R4X scratch buffers file-backed instead of BSS-only.
var service_payload_buffer: [r4os.abi.service_api_max_payload]u8 = .{0xA5} ** r4os.abi.service_api_max_payload;
var service_status_reply: r4os.abi.NetServiceR4slStatus = .{};
var service_result_reply: r4os.abi.NetServiceR4slResult = .{};
var selftest_status_response: [@sizeOf(r4os.abi.NetServiceR4slStatus)]u8 = .{0xA5} ** @sizeOf(r4os.abi.NetServiceR4slStatus);
var selftest_result_response: [@sizeOf(r4os.abi.NetServiceR4slResult)]u8 = .{0xA5} ** @sizeOf(r4os.abi.NetServiceR4slResult);

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var app = App.init(r4_app) orelse return r4os.abi.err_no_group;
    if (hasArg(app.sys.argsRaw(), selftest_arg)) return runSelfTest(&app);
    if (hasArg(app.sys.argsRaw(), ping_arg)) return runPing(&app);
    return runService(&app);
}

fn runService(app: *const App) i32 {
    if (!app.sys.hasFn("service_call")) return r4os.abi.service_api_result_invalid;

    var info: r4os.abi.ServiceInfo = .{};
    var handle: u32 = 0;
    var waited: u32 = 0;
    while (waited < 100 and handle == 0) : (waited += 1) {
        const rc = app.sys.serviceEndpointRegister(service_name, 0, &info);
        if (rc == r4os.abi.service_api_result_ok and info.handle != 0) {
            handle = info.handle;
            app.sys.write("R4SLSVC endpoint handle=");
            app.sys.printU64(@intCast(handle));
            app.sys.println("");
            break;
        }
        app.sys.sleepTicks(1);
    }
    if (handle == 0) {
        app.sys.println("R4SLSVC endpoint registration failed");
        return r4os.abi.service_api_result_no_endpoint;
    }

    var state = ServiceState{};
    setLastError(&state, "ready");
    syncKernel(app, &state);

    while (!app.sys.programShouldClose()) {
        syncKernel(app, &state);
        const poll = app.sys.serviceEndpointPoll(handle);
        if (poll < 0) {
            clearQueues(&state, true);
            _ = app.sys.serviceEndpointUnregister(handle);
            return poll;
        }
        if (poll > 0) {
            const rc = handleRequest(app, handle, &state);
            if (rc < 0) {
                clearQueues(&state, true);
                _ = app.sys.serviceEndpointUnregister(handle);
                return rc;
            }
        }
        app.sys.sleepTicks(1);
    }

    clearQueues(&state, true);
    _ = app.sys.serviceEndpointUnregister(handle);
    app.sys.println("R4SLSVC stopped cleanly");
    return 0;
}

fn handleRequest(app: *const App, handle: u32, state: *ServiceState) i32 {
    var header: r4os.abi.ServiceMessageHeader = .{};
    const got = app.sys.serviceEndpointRecv(handle, &header, service_payload_buffer[0..]);
    if (got < 0) return got;
    if (got == 0 and header.magic != r4os.abi.service_api_magic) return 0;

    state.requests +%= 1;
    const payload_len: usize = @intCast(got);
    const request = service_payload_buffer[0..payload_len];
    return switch (header.op) {
        r4os.abi.net_service_op_status => replyTextStatus(app, handle, header.request_id, state),
        r4os.abi.net_service_op_r4sl_status_result => replyStatusResult(app, handle, header.request_id, state),
        r4os.abi.net_service_op_r4sl_poll, r4os.abi.net_service_op_r4sl_poll_result => replyPoll(app, handle, header.request_id, state),
        r4os.abi.net_service_op_r4sl_send_message, r4os.abi.net_service_op_r4sl_send_message_result => replySendMessage(app, handle, header.request_id, request, state),
        r4os.abi.net_service_op_r4sl_read_message, r4os.abi.net_service_op_r4sl_read_message_result => replyReadMessage(app, handle, header.request_id, state),
        r4os.abi.net_service_op_r4sl_selftest, r4os.abi.net_service_op_r4sl_selftest_result => replySelfTest(app, handle, header.request_id, state),
        r4os.abi.net_service_op_r4sl_hosttest, r4os.abi.net_service_op_r4sl_hosttest_result => replyHostTest(app, handle, header.request_id, state),
        r4os.abi.net_service_op_r4sl_reset, r4os.abi.net_service_op_r4sl_reset_result => replyReset(app, handle, header.request_id, state),
        else => {
            state.bad_ops +%= 1;
            return app.sys.serviceEndpointReply(handle, header.request_id, r4os.abi.service_api_result_bad_op, "BADOP");
        },
    };
}

fn replyTextStatus(app: *const App, handle: u32, request_id: u32, state: *ServiceState) i32 {
    state.status_requests +%= 1;
    syncKernel(app, state);
    var buf: [512]u8 = .{0} ** 512;
    var w = Writer{ .out = buf[0..] };
    writeStatusText(&w, state);
    return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, w.slice());
}

fn replyStatusResult(app: *const App, handle: u32, request_id: u32, state: *ServiceState) i32 {
    state.status_requests +%= 1;
    syncKernel(app, state);
    service_status_reply = makeStatus(state);
    const bytes: [*]const u8 = @ptrCast(&service_status_reply);
    return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, bytes[0..@sizeOf(r4os.abi.NetServiceR4slStatus)]);
}

fn replyPoll(app: *const App, handle: u32, request_id: u32, state: *ServiceState) i32 {
    state.poll_requests +%= 1;
    const rc = app.net.serialLinkPoll();
    state.last_result = if (rc >= 0) r4os.abi.serial_link_result_ok else rc;
    syncKernel(app, state);
    service_result_reply = makeResult(state, r4os.abi.net_service_r4sl_action_poll, state.last_result, "");
    return replyResult(app, handle, request_id);
}

fn replySendMessage(app: *const App, handle: u32, request_id: u32, payload: []const u8, state: *ServiceState) i32 {
    state.send_requests +%= 1;
    if (payload.len > MAX_PAYLOAD) {
        state.last_result = r4os.abi.serial_link_result_too_large;
        setLastError(state, "too-large");
    } else if (!pushQueue(&state.outbox, &state.outbox_count, payload)) {
        state.drops +%= 1;
        state.last_result = r4os.abi.serial_link_result_failed;
        setLastError(state, "outbox-full");
    } else {
        copyLastServiceMessage(state, payload);
        flushOutbox(app, state);
    }
    syncKernel(app, state);
    service_result_reply = makeResult(state, r4os.abi.net_service_r4sl_action_send_message, state.last_result, payload);
    return replyResult(app, handle, request_id);
}

fn replyReadMessage(app: *const App, handle: u32, request_id: u32, state: *ServiceState) i32 {
    state.read_requests +%= 1;
    syncKernel(app, state);
    var msg = r4os.abi.SerialLinkMessage{};
    if (popQueue(&state.inbox, &state.inbox_count, &msg)) {
        const len: usize = @intCast(msg.len);
        state.last_result = r4os.abi.serial_link_result_ok;
        setLastError(state, "read");
        service_result_reply = makeResult(state, r4os.abi.net_service_r4sl_action_read_message, state.last_result, msg.data[0..len]);
    } else {
        state.last_result = 0;
        setLastError(state, "empty");
        service_result_reply = makeResult(state, r4os.abi.net_service_r4sl_action_read_message, state.last_result, "");
    }
    return replyResult(app, handle, request_id);
}

fn replySelfTest(app: *const App, handle: u32, request_id: u32, state: *ServiceState) i32 {
    state.self_tests +%= 1;
    state.last_result = if (serviceContractSelfTest(app, state)) r4os.abi.serial_link_result_ok else r4os.abi.serial_link_result_failed;
    setLastError(state, if (state.last_result == r4os.abi.serial_link_result_ok) "selftest" else "selftest-failed");
    syncKernel(app, state);
    service_result_reply = makeResult(state, r4os.abi.net_service_r4sl_action_selftest, state.last_result, "");
    return replyResult(app, handle, request_id);
}

fn replyHostTest(app: *const App, handle: u32, request_id: u32, state: *ServiceState) i32 {
    state.host_tests +%= 1;
    const rc = app.net.serialLinkHostTest();
    state.last_result = rc;
    setLastError(state, if (rc == r4os.abi.serial_link_result_ok) "hosttest" else "hosttest-failed");
    syncKernel(app, state);
    service_result_reply = makeResult(state, r4os.abi.net_service_r4sl_action_hosttest, rc, "");
    return replyResult(app, handle, request_id);
}

fn replyReset(app: *const App, handle: u32, request_id: u32, state: *ServiceState) i32 {
    clearQueues(state, false);
    state.last_result = r4os.abi.serial_link_result_ok;
    setLastError(state, "reset");
    syncKernel(app, state);
    service_result_reply = makeResult(state, r4os.abi.net_service_r4sl_action_reset, state.last_result, "");
    return replyResult(app, handle, request_id);
}

fn replyResult(app: *const App, handle: u32, request_id: u32) i32 {
    const bytes: [*]const u8 = @ptrCast(&service_result_reply);
    return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, bytes[0..@sizeOf(r4os.abi.NetServiceR4slResult)]);
}

fn flushOutbox(app: *const App, state: *ServiceState) void {
    while (state.outbox_count != 0) {
        const item = state.outbox[0];
        const len: usize = @intCast(item.len);
        const rc = app.net.serialLinkSendMessage(item.data[0..len]);
        if (rc < 0) {
            state.last_result = rc;
            setLastError(state, serialResultName(rc));
            return;
        }
        discardFirst(&state.outbox, &state.outbox_count);
        state.last_result = r4os.abi.serial_link_result_ok;
        setLastError(state, "sent");
    }
}

fn syncKernel(app: *const App, state: *ServiceState) void {
    var status = r4os.abi.SerialLinkStatus{};
    const rc = app.net.serialLinkStatus(&status);
    if (rc < 0) {
        state.last_result = r4os.abi.serial_link_result_failed;
        setLastError(state, "kernel-api");
        return;
    }
    state.kernel = status;
    if (status.message_rx != state.last_kernel_message_rx) {
        var msg = r4os.abi.SerialLinkMessage{};
        const got = app.net.serialLinkInbox(&msg);
        if (got > 0) {
            const len: usize = @intCast(msg.len);
            if (!pushQueue(&state.inbox, &state.inbox_count, msg.data[0..len])) state.drops +%= 1;
            copyLastServiceMessage(state, msg.data[0..len]);
        }
        state.last_kernel_message_rx = status.message_rx;
    }
}

fn makeStatus(state: *const ServiceState) r4os.abi.NetServiceR4slStatus {
    var out = r4os.abi.NetServiceR4slStatus{
        .flags = serviceFlags(state),
        .last_result = state.last_result,
        .inbox_count = state.inbox_count,
        .outbox_count = state.outbox_count,
        .queue_capacity = QUEUE_CAPACITY,
        .last_service_message_len = state.last_service_message_len,
        .requests = state.requests,
        .status_requests = state.status_requests,
        .poll_requests = state.poll_requests,
        .send_requests = state.send_requests,
        .read_requests = state.read_requests,
        .self_tests = state.self_tests,
        .host_tests = state.host_tests,
        .bad_ops = state.bad_ops,
        .queue_clears = state.queue_clears,
        .drops = state.drops,
        .cancelled = state.cancelled,
        .kernel = state.kernel,
    };
    const len: usize = @intCast(state.last_service_message_len);
    if (len != 0) copyBytes(out.last_service_message[0..len], state.last_service_message[0..len]);
    copyFixed(out.last_error[0..], spanZ(state.last_error[0..]));
    return out;
}

fn makeResult(state: *const ServiceState, action: u16, result: i32, message: []const u8) r4os.abi.NetServiceR4slResult {
    var flags = serviceFlags(state);
    flags = withServiceStatus(flags, serviceStatusFromSerialResult(result));
    var out = r4os.abi.NetServiceR4slResult{
        .action = action,
        .result = result,
        .flags = flags,
        .bytes = @intCast(@min(message.len, MAX_PAYLOAD)),
        .requested_bytes = @intCast(@min(message.len, MAX_PAYLOAD)),
        .inbox_count = state.inbox_count,
        .outbox_count = state.outbox_count,
        .message_len = @intCast(@min(message.len, MAX_PAYLOAD)),
        .kernel = state.kernel,
    };
    const len: usize = @intCast(out.message_len);
    if (len != 0) copyBytes(out.message[0..len], message[0..len]);
    copyFixed(out.last_error[0..], spanZ(state.last_error[0..]));
    return out;
}

fn serviceFlags(state: *const ServiceState) u32 {
    var flags: u32 = 0;
    if (state.kernel.present != 0) flags |= r4os.abi.net_service_r4sl_flag_present;
    if (state.kernel.initialized != 0) flags |= r4os.abi.net_service_r4sl_flag_initialized;
    if (state.inbox_count != 0) flags |= r4os.abi.net_service_r4sl_flag_inbox_data;
    if (state.outbox_count != 0) flags |= r4os.abi.net_service_r4sl_flag_outbox_data;
    if (state.kernel.message_rx != 0) flags |= r4os.abi.net_service_r4sl_flag_kernel_message;
    if (state.inbox_count != 0 or state.outbox_count != 0) flags |= r4os.abi.net_service_r4sl_flag_service_queue;
    return flags;
}

fn writeStatusText(w: *Writer, state: *const ServiceState) void {
    w.text("present=");
    w.text(if (state.kernel.present != 0) "yes" else "no");
    w.text(" initialized=");
    w.text(if (state.kernel.initialized != 0) "yes" else "no");
    w.text(" inbox=");
    w.num(state.inbox_count);
    w.text(" outbox=");
    w.num(state.outbox_count);
    w.text(" tx=");
    w.num(state.kernel.tx_frames);
    w.text(" rx=");
    w.num(state.kernel.rx_frames);
    w.text(" msg_tx=");
    w.num(state.kernel.message_tx);
    w.text(" msg_rx=");
    w.num(state.kernel.message_rx);
    w.text(" bad_magic=");
    w.num(state.kernel.bad_magic);
    w.text(" checksum=");
    w.num(state.kernel.checksum_errors);
    w.text(" timeout=");
    w.num(state.kernel.timeouts);
    w.text(" last=");
    w.text(spanZ(state.last_error[0..]));
}

fn runPing(app: *const App) i32 {
    app.sys.println("R4SLSVC ping");
    var handle: u32 = 0;
    if (!ensureRunningAndOpen(app, &handle)) {
        app.sys.println("R4SLSVC ping failed");
        return 1;
    }
    defer _ = app.sys.serviceClose(handle);

    var header: r4os.abi.ServiceMessageHeader = .{};
    const got = app.sys.serviceCall(handle, r4os.abi.net_service_op_r4sl_status_result, "", &header, selftest_status_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceR4slStatus))) or header.status != r4os.abi.service_api_result_ok) {
        app.sys.println("R4SLSVC ping failed");
        return 1;
    }
    var status = r4os.abi.NetServiceR4slStatus{};
    copyStruct(&status, selftest_status_response[0..]);
    if (status.magic != r4os.abi.net_service_r4sl_status_magic or status.version != r4os.abi.net_service_r4sl_status_version) {
        app.sys.println("R4SLSVC ping failed");
        return 1;
    }
    app.sys.println("R4SLSVC ping: OK");
    return 0;
}

fn runSelfTest(app: *const App) i32 {
    app.sys.println("R4SLSVC selftest");
    if (!app.sys.hasFn("service_start")) return fail(app, "manager-api");
    if (!app.sys.hasFn("service_call")) return fail(app, "service-api");
    if (!app.net.hasFn("serial_link_status")) return fail(app, "serial-api");
    if (!localContractSelfTest()) return fail(app, "local-contract");

    var handle: u32 = 0;
    if (!ensureRunningAndOpen(app, &handle)) return fail(app, "open");

    var header: r4os.abi.ServiceMessageHeader = .{};
    const status_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_r4sl_status_result, "", &header, selftest_status_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (status_got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceR4slStatus))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "status");
    var status = r4os.abi.NetServiceR4slStatus{};
    copyStruct(&status, selftest_status_response[0..]);
    if (status.magic != r4os.abi.net_service_r4sl_status_magic or status.version != r4os.abi.net_service_r4sl_status_version) return fail(app, "status-magic");

    const poll_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_r4sl_poll_result, "", &header, selftest_result_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (poll_got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceR4slResult))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "poll");

    const svc_self_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_r4sl_selftest_result, "", &header, selftest_result_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (svc_self_got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceR4slResult))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "service-selftest");
    var result = r4os.abi.NetServiceR4slResult{};
    copyStruct(&result, selftest_result_response[0..]);
    if (result.magic != r4os.abi.net_service_r4sl_result_magic or result.result != r4os.abi.serial_link_result_ok) return fail(app, "service-selftest-result");

    const send_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_r4sl_send_message_result, "R4SLSVC-QUEUE", &header, selftest_result_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (send_got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceR4slResult))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "send");

    var small: [8]u8 = .{0} ** 8;
    const bad_op = app.sys.serviceCall(handle, 0xFFFF, "", &header, small[0..], app.sys.ticksFromMilliseconds(100));
    if (bad_op < 0 or header.status != r4os.abi.service_api_result_bad_op) return fail(app, "bad-op");

    _ = app.sys.serviceClose(handle);
    var info: r4os.abi.ServiceInfo = .{};
    const restart = app.sys.serviceRestart(service_name, &info);
    if (restart != r4os.abi.service_api_result_ok or info.state != r4os.abi.service_state_running) return fail(app, "restart");
    if (!ensureRunningAndOpen(app, &handle)) return fail(app, "reopen");
    defer _ = app.sys.serviceClose(handle);

    const after_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_r4sl_status_result, "", &header, selftest_status_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (after_got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceR4slStatus))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "after-restart-status");
    copyStruct(&status, selftest_status_response[0..]);
    if (status.inbox_count != 0 or status.outbox_count != 0) return fail(app, "restart-queue-clear");

    app.sys.println("R4SLSVC selftest: OK");
    return 0;
}

fn localContractSelfTest() bool {
    var state = ServiceState{};
    setLastError(&state, "selftest");
    const payload = "R4SLSVC-SELF";
    var frame: [MAX_FRAME]u8 = .{0} ** MAX_FRAME;
    const len = buildFrame(TYPE_DIAG, payload, frame[0..]) orelse return false;
    var frame_type: u8 = 0;
    var parsed: [MAX_PAYLOAD]u8 = .{0} ** MAX_PAYLOAD;
    const parsed_len = parseFrame(frame[0..len], &frame_type, parsed[0..]) orelse return false;
    if (frame_type != TYPE_DIAG or parsed_len != payload.len or !memEql(parsed[0..parsed_len], payload)) return false;

    frame[0] = 'X';
    if (parseFrame(frame[0..len], &frame_type, parsed[0..]) != null) return false;

    if (!pushQueue(&state.inbox, &state.inbox_count, "IN")) return false;
    if (!pushQueue(&state.outbox, &state.outbox_count, "OUT")) return false;
    if (state.inbox_count != 1 or state.outbox_count != 1) return false;
    var msg = r4os.abi.SerialLinkMessage{};
    if (!popQueue(&state.inbox, &state.inbox_count, &msg) or msg.len != 2) return false;
    clearQueues(&state, false);
    return state.inbox_count == 0 and state.outbox_count == 0 and state.queue_clears == 1;
}

fn serviceContractSelfTest(app: *const App, state: *ServiceState) bool {
    if (!localContractSelfTest()) return false;
    if (app.net.serialLinkPoll() < 0) return false;
    syncKernel(app, state);
    const status = state.kernel;
    if (status.max_payload != @as(u16, @intCast(r4os.abi.serial_link_payload_max))) return false;
    if (status.present != 0 and status.initialized == 0) return false;
    var inbox = r4os.abi.SerialLinkMessage{};
    const inbox_rc = app.net.serialLinkInbox(&inbox);
    return inbox_rc >= 0 and inbox.len <= @as(u16, @intCast(r4os.abi.serial_link_payload_max));
}

fn ensureRunningAndOpen(app: *const App, out_handle: *u32) bool {
    var info: r4os.abi.ServiceInfo = .{};
    const status = app.sys.serviceStatus(service_name, &info);
    if (status != r4os.abi.service_api_result_ok) return false;
    if (info.state != r4os.abi.service_state_running) {
        const start = app.sys.serviceStart(service_name, &info);
        if (start != r4os.abi.service_api_result_ok) return false;
    }
    var tick: u32 = 0;
    while (tick < 160) : (tick += 1) {
        const open_rc = app.sys.serviceOpen(service_name, &info);
        if (open_rc == r4os.abi.service_api_result_ok and info.handle != 0) {
            out_handle.* = info.handle;
            return true;
        }
        app.sys.sleepTicks(1);
    }
    return false;
}

fn pushQueue(queue: *[QUEUE_CAPACITY]QueueItem, count: *u16, payload: []const u8) bool {
    if (payload.len > MAX_PAYLOAD or count.* >= QUEUE_CAPACITY) return false;
    const index: usize = @intCast(count.*);
    queue[index] = .{ .len = @intCast(payload.len) };
    if (payload.len != 0) copyBytes(queue[index].data[0..payload.len], payload);
    count.* += 1;
    return true;
}

fn popQueue(queue: *[QUEUE_CAPACITY]QueueItem, count: *u16, out: *r4os.abi.SerialLinkMessage) bool {
    out.* = .{};
    if (count.* == 0) return false;
    const item = queue[0];
    out.len = item.len;
    const len: usize = @intCast(item.len);
    if (len != 0) copyBytes(out.data[0..len], item.data[0..len]);
    discardFirst(queue, count);
    return true;
}

fn discardFirst(queue: *[QUEUE_CAPACITY]QueueItem, count: *u16) void {
    if (count.* == 0) return;
    var i: usize = 1;
    while (i < @as(usize, @intCast(count.*))) : (i += 1) queue[i - 1] = queue[i];
    count.* -= 1;
    queue[@intCast(count.*)] = .{};
}

fn clearQueues(state: *ServiceState, cancelled: bool) void {
    if (cancelled) state.cancelled +%= state.inbox_count + state.outbox_count;
    state.inbox = .{QueueItem{}} ** QUEUE_CAPACITY;
    state.outbox = .{QueueItem{}} ** QUEUE_CAPACITY;
    state.inbox_count = 0;
    state.outbox_count = 0;
    state.queue_clears +%= 1;
}

fn copyLastServiceMessage(state: *ServiceState, payload: []const u8) void {
    state.last_service_message = .{0} ** MAX_PAYLOAD;
    const len = @min(payload.len, MAX_PAYLOAD);
    state.last_service_message_len = @intCast(len);
    if (len != 0) copyBytes(state.last_service_message[0..len], payload[0..len]);
}

fn buildFrame(frame_type: u8, payload: []const u8, out: []u8) ?usize {
    if (payload.len > MAX_PAYLOAD or out.len < HEADER_SIZE + payload.len) return null;
    out[0] = MAGIC[0];
    out[1] = MAGIC[1];
    out[2] = MAGIC[2];
    out[3] = MAGIC[3];
    out[4] = VERSION;
    out[5] = frame_type;
    writeLe16(out[6..8], @intCast(payload.len));
    out[8] = 0;
    out[9] = 0;
    if (payload.len != 0) copyBytes(out[HEADER_SIZE .. HEADER_SIZE + payload.len], payload);
    writeLe16(out[8..10], checksum(out[0 .. HEADER_SIZE + payload.len]));
    return HEADER_SIZE + payload.len;
}

fn parseFrame(frame: []const u8, frame_type: *u8, out: []u8) ?usize {
    if (frame.len < HEADER_SIZE or frame[0] != MAGIC[0] or frame[1] != MAGIC[1] or frame[2] != MAGIC[2] or frame[3] != MAGIC[3]) return null;
    if (frame[4] != VERSION) return null;
    const payload_len: usize = @intCast(readLe16(frame[6..8]));
    if (payload_len > MAX_PAYLOAD or frame.len != HEADER_SIZE + payload_len or out.len < payload_len) return null;
    if (checksum(frame) != readLe16(frame[8..10])) return null;
    frame_type.* = frame[5];
    if (payload_len != 0) copyBytes(out[0..payload_len], frame[HEADER_SIZE .. HEADER_SIZE + payload_len]);
    return payload_len;
}

fn checksum(frame: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < frame.len) : (i += 1) {
        if (i == 8 or i == 9) continue;
        sum += frame[i];
    }
    return @truncate(sum & 0xFFFF);
}

fn readLe16(data: []const u8) u16 {
    return @as(u16, data[0]) | (@as(u16, data[1]) << 8);
}

fn writeLe16(out: []u8, value: u16) void {
    out[0] = @truncate(value & 0x00FF);
    out[1] = @truncate(value >> 8);
}

fn serviceStatusFromSerialResult(result: i32) u32 {
    return switch (result) {
        r4os.abi.serial_link_result_ok => r4os.abi.net_service_status_ok,
        r4os.abi.serial_link_result_no_port, r4os.abi.serial_link_result_not_initialized => r4os.abi.net_service_status_would_block,
        else => r4os.abi.net_service_status_failed,
    };
}

fn withServiceStatus(flags: u32, status: u32) u32 {
    return (flags & ~r4os.abi.net_service_status_mask) | (status << r4os.abi.net_service_status_shift);
}

fn serialResultName(result: i32) []const u8 {
    return switch (result) {
        r4os.abi.serial_link_result_ok => "ok",
        r4os.abi.serial_link_result_no_port => "no-port",
        r4os.abi.serial_link_result_not_initialized => "not-initialized",
        r4os.abi.serial_link_result_too_large => "too-large",
        else => "failed",
    };
}

fn fail(app: *const App, label: []const u8) i32 {
    app.sys.write("R4SLSVC selftest FAILED: ");
    app.sys.println(label);
    return 1;
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn upper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - ('a' - 'A');
    return ch;
}

fn copyStruct(out: anytype, data: []const u8) void {
    const out_bytes: [*]u8 = @ptrCast(out);
    const size = @sizeOf(@TypeOf(out.*));
    const len = @min(size, data.len);
    var i: usize = 0;
    while (i < len) : (i += 1) out_bytes[i] = data[i];
}

fn copyFixed(out: []u8, value: []const u8) void {
    @memset(out, 0);
    if (out.len == 0) return;
    const len = @min(value.len, out.len - 1);
    if (len != 0) copyBytes(out[0..len], value[0..len]);
}

fn setLastError(state: *ServiceState, value: []const u8) void {
    copyFixed(state.last_error[0..], value);
}

fn copyBytes(out: []u8, value: []const u8) void {
    var i: usize = 0;
    while (i < out.len and i < value.len) : (i += 1) out[i] = value[i];
}

fn spanZ(value: []const u8) []const u8 {
    return value[0..stringLenZ(value)];
}

fn stringLenZ(value: []const u8) usize {
    var len: usize = 0;
    while (len < value.len and value[len] != 0) : (len += 1) {}
    return len;
}

fn memEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

const Writer = struct {
    out: []u8,
    pos: usize = 0,

    fn put(self: *Writer, ch: u8) void {
        if (self.pos >= self.out.len) return;
        self.out[self.pos] = ch;
        self.pos += 1;
    }

    fn text(self: *Writer, value: []const u8) void {
        for (value) |ch| if (ch != 0) self.put(ch);
    }

    fn slice(self: *const Writer) []const u8 {
        return self.out[0..self.pos];
    }

    fn num(self: *Writer, value: anytype) void {
        var buf: [20]u8 = undefined;
        var pos: usize = buf.len;
        var n: u64 = @intCast(value);
        if (n == 0) {
            self.put('0');
            return;
        }
        while (n > 0) {
            pos -= 1;
            buf[pos] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
        }
        self.text(buf[pos..]);
    }
};
