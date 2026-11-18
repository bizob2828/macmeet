import CoreImage
import CoreMedia
import os
import ScreenCaptureKit

/// Captures a display or window with ScreenCaptureKit and hands each frame over as a base64 JPEG.
final class ScreenCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  let size: CGSize

  private let filter: SCContentFilter
  private let configuration: SCStreamConfiguration
  private let onFrame: @Sendable (ScreenCaptureSession, String) -> Void
  private let onStop: @Sendable (ScreenCaptureSession) -> Void
  private let queue = DispatchQueue(label: "macmeet.screen-capture")
  private let ciContext = CIContext()
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

  /// True while a frame is on its way to the page. Frames that arrive meanwhile are dropped
  /// rather than queued, so a slow page never falls behind the screen.
  private let frameInFlight = OSAllocatedUnfairLock(initialState: false)
  private var stream: SCStream?

  /// Longest edge sent to Meet. Larger frames cost a lot to encode and transfer for no visible gain.
  private static let maxDimension: CGFloat = 1920

  init(
    filter: SCContentFilter,
    frameRate: Int,
    onFrame: @escaping @Sendable (ScreenCaptureSession, String) -> Void,
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

    let configuration = SCStreamConfiguration()
    configuration.width = Int(size.width)
    configuration.height = Int(size.height)
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = true
    configuration.queueDepth = 3

    self.filter = filter
    self.configuration = configuration
    self.onFrame = onFrame
    self.onStop = onStop
    super.init()
  }

  func start() async throws {
    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    try await stream.startCapture()
    self.stream = stream
  }

  func stop() {
    guard let stream else { return }
    self.stream = nil
    Task { try? await stream.stopCapture() }
  }

  func frameDelivered() {
    frameInFlight.withLock { $0 = false }
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
          let pixelBuffer = sampleBuffer.imageBuffer else { return }

    let claimed = frameInFlight.withLock { busy in
      if busy { return false }
      busy = true
      return true
    }
    guard claimed else { return }

    let image = CIImage(cvPixelBuffer: pixelBuffer)
    guard let jpeg = ciContext.jpegRepresentation(
      of: image,
      colorSpace: colorSpace,
      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.75]
    ) else {
      frameDelivered()
      return
    }
    onFrame(self, jpeg.base64EncodedString())
  }

  // MARK: - SCStreamDelegate

  /// Called when capture ends outside our control, e.g. the user stops it from the macOS menu bar
  /// or the shared window closes.
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    onStop(self)
  }
}
