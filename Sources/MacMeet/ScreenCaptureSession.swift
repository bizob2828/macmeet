import CoreMedia
import os
import ScreenCaptureKit
import VideoToolbox

/// Captures a display or window with ScreenCaptureKit and encodes it as HEVC with the hardware
/// encoder. Each frame is delivered as length-prefixed NAL units, which the page decodes with
/// WebCodecs.
///
/// HEVC rather than H.264: WebKit's H.264 decoder holds about a dozen frames before outputting
/// any, because VideoToolbox's H.264 streams don't declare that frames are never reordered. HEVC
/// streams always declare it, so each frame is shown as soon as it's decoded.
final class ScreenCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  struct EncodedFrame: Sendable {
    /// Base64 length-prefixed NAL units.
    let data: String
    let isKeyFrame: Bool
    let timestamp: Int
    /// WebCodecs decoder configuration, sent with every key frame.
    let codec: String?
    let description: String?

    var dictionary: [String: Any] {
      var dictionary: [String: Any] = ["data": data, "key": isKeyFrame, "timestamp": timestamp]
      if let codec, let description {
        dictionary["codec"] = codec
        dictionary["description"] = description
      }
      return dictionary
    }
  }

  let size: CGSize

  private let filter: SCContentFilter
  private let configuration: SCStreamConfiguration
  private let frameRate: Int
  private let onFrame: @Sendable (ScreenCaptureSession, EncodedFrame) -> Void
  private let onStop: @Sendable (ScreenCaptureSession) -> Void
  private let queue = DispatchQueue(label: "macmeet.screen-capture")

  /// True while a frame is being encoded or is on its way to the page. Frames that arrive
  /// meanwhile are dropped before encoding, so a slow page never falls behind the screen.
  private let frameInFlight = OSAllocatedUnfairLock(initialState: false)
  private let keyFrameRequested = OSAllocatedUnfairLock(initialState: false)
  private var stream: SCStream?
  private var encoder: VTCompressionSession?

  /// Longest edge sent to Meet. Larger frames cost a lot to encode and transfer for no visible gain.
  private static let maxDimension: CGFloat = 1920

  init(
    filter: SCContentFilter,
    frameRate: Int,
    onFrame: @escaping @Sendable (ScreenCaptureSession, EncodedFrame) -> Void,
    onStop: @escaping @Sendable (ScreenCaptureSession) -> Void
  ) {
    let pixels = CGSize(
      width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
      height: filter.contentRect.height * CGFloat(filter.pointPixelScale)
    )
    let scale = min(1, Self.maxDimension / max(pixels.width, pixels.height, 1))
    size = CGSize(
      width: max(2, (pixels.width * scale / 2).rounded() * 2),
      height: max(2, (pixels.height * scale / 2).rounded() * 2)
    )

    // Capture straight into the encoder's native format, so frames need no color conversion.
    let configuration = SCStreamConfiguration()
    configuration.width = Int(size.width)
    configuration.height = Int(size.height)
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
    configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
    configuration.showsCursor = true
    configuration.queueDepth = 3

    self.filter = filter
    self.configuration = configuration
    self.frameRate = frameRate
    self.onFrame = onFrame
    self.onStop = onStop
    super.init()
  }

  func start() async throws {
    encoder = try makeEncoder()
    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    try await stream.startCapture()
    self.stream = stream
  }

  func stop() {
    guard let stream else { return }
    self.stream = nil
    Task { try? await stream.stopCapture() }
    queue.async { [self] in
      if let encoder {
        VTCompressionSessionInvalidate(encoder)
        self.encoder = nil
      }
    }
  }

  func frameDelivered() {
    frameInFlight.withLock { $0 = false }
  }

  /// The page lost its decoder state; the next frame starts over with a key frame.
  func requestKeyFrame() {
    keyFrameRequested.withLock { $0 = true }
  }

  // MARK: - Encoding

  private func makeEncoder() throws -> VTCompressionSession {
    var session: VTCompressionSession?
    let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
    let status = VTCompressionSessionCreate(
      allocator: nil,
      width: Int32(size.width),
      height: Int32(size.height),
      codecType: kCMVideoCodecType_HEVC,
      encoderSpecification: specification,
      imageBufferAttributes: nil,
      compressedDataAllocator: nil,
      outputCallback: nil,
      refcon: nil,
      compressionSessionOut: &session
    )
    guard status == noErr, let session else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
        NSLocalizedDescriptionKey: "Couldn't start the video encoder (\(status)).",
      ])
    }

    // The stream only goes to the page in this process, so bandwidth is cheap: use a high bit
    // rate to keep text sharp before Meet re-encodes it.
    let bitRate = Int(size.width * size.height) * 4
    let properties: [CFString: Any] = [
      kVTCompressionPropertyKey_RealTime: true,
      kVTCompressionPropertyKey_AllowFrameReordering: false,
      kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main_AutoLevel,
      kVTCompressionPropertyKey_AverageBitRate: bitRate,
      kVTCompressionPropertyKey_ExpectedFrameRate: frameRate,
      kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 60,
      kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
      kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
      kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
    ]
    VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
    VTCompressionSessionPrepareToEncodeFrames(session)
    return session
  }

  private func handleEncoded(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
    guard status == noErr,
          let sampleBuffer,
          let dataBuffer = sampleBuffer.dataBuffer,
          let data = try? dataBuffer.dataBytes() else {
      frameDelivered()
      return
    }

    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
      as? [[CFString: Any]]
    let isKeyFrame = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true

    var codec: String?
    var description: String?
    if isKeyFrame,
       let format = sampleBuffer.formatDescription,
       let atoms = CMFormatDescriptionGetExtension(
         format,
         extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
       ) as? [String: Any],
       let hvcC = atoms["hvcC"] as? Data,
       let codecString = Self.codecString(hvcC: hvcC) {
      codec = codecString
      description = hvcC.base64EncodedString()
    }

    let timestamp = Int(sampleBuffer.presentationTimeStamp.seconds * 1_000_000)
    onFrame(self, EncodedFrame(
      data: data.base64EncodedString(),
      isKeyFrame: isKeyFrame,
      timestamp: timestamp,
      codec: codec,
      description: description
    ))
  }

  /// The WebCodecs codec string for an HEVC stream, such as "hvc1.1.6.L123.B0", built from its
  /// hvcC record as described in ISO/IEC 14496-15 annex E.
  private static func codecString(hvcC: Data) -> String? {
    let bytes = [UInt8](hvcC)
    guard bytes.count >= 13 else { return nil }
    let profileSpace = ["", "A", "B", "C"][Int(bytes[1] >> 6)]
    let tier = bytes[1] & 0x20 == 0 ? "L" : "H"
    let profile = bytes[1] & 0x1f
    // The compatibility flags are written in reverse bit order.
    let compatibility = bytes[2...5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    let constraints = bytes[6...11].reversed().drop { $0 == 0 }.reversed()
    let parts = [
      "hvc1",
      "\(profileSpace)\(profile)",
      String(compatibility.bitReversed, radix: 16, uppercase: true),
      "\(tier)\(bytes[12])",
    ] + constraints.map { String($0, radix: 16, uppercase: true) }
    return parts.joined(separator: ".")
  }

  // MARK: - SCStreamOutput

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    // ScreenCaptureKit also sends idle and blank frames that carry no new image.
    guard type == .screen,
          sampleBuffer.isValid,
          let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
          let rawStatus = attachments.first?[.status] as? Int,
          SCFrameStatus(rawValue: rawStatus) == .complete,
          let pixelBuffer = sampleBuffer.imageBuffer,
          let encoder else { return }

    let claimed = frameInFlight.withLock { busy in
      if busy { return false }
      busy = true
      return true
    }
    guard claimed else { return }

    let forceKeyFrame = keyFrameRequested.withLock { requested in
      defer { requested = false }
      return requested
    }
    let frameProperties = forceKeyFrame
      ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
      : nil

    let status = VTCompressionSessionEncodeFrame(
      encoder,
      imageBuffer: pixelBuffer,
      presentationTimeStamp: sampleBuffer.presentationTimeStamp,
      duration: .invalid,
      frameProperties: frameProperties,
      infoFlagsOut: nil
    ) { [self] status, _, encoded in
      handleEncoded(status: status, sampleBuffer: encoded)
    }
    if status != noErr { frameDelivered() }
  }

  // MARK: - SCStreamDelegate

  /// Called when capture ends outside our control, e.g. the user stops it from the macOS menu bar
  /// or the shared window closes.
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    onStop(self)
  }
}

private extension UInt32 {
  var bitReversed: UInt32 {
    (0..<32).reduce(UInt32(0)) { reversed, bit in reversed << 1 | (self >> bit & 1) }
  }
}
