/// 受保护通道载荷的**平台接缝**（`v0.16.4` / FR-92）。
///
/// - 原生：大载荷（≥ [kChannelOffMainThreshold]）在工作 isolate 内封装 / 解封，
///   UI isolate 只做数据转移；
/// - Web：同线程执行（浏览器无 isolate），线路字节一致。
///
/// 线路格式与 `v0.16.3` 逐字节一致；本文件只决定**在哪里算**，不改变算什么。
library;

export 'channel_payload_core.dart'
    show
        ChannelPayloadException,
        kChannelOffMainThreshold,
        openChannelEnvelopeInline,
        sealChannelEnvelopeInline;

export 'channel_payload_io.dart'
    if (dart.library.js_interop) 'channel_payload_web.dart';
