#if os(macOS)
import CoreVideo
import VideoToolbox

/// Converts capture-card YUV to BGRA with the right colour matrix (0.80.1). AVFoundation's own
/// conversion falls back to BT.601 when a card (e.g. Datavideo CAP-2) leaves the matrix untagged
/// or tags it wrongly, which shifts HD colours (reds/skin and greens off). HD (720 lines and up)
/// is BT.709, SD is BT.601. Used on the capture queue only.
final class CaptureColorConverter {
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var width = 0, height = 0

    func bgra(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        let matrix = h >= 720 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
        CVBufferSetAttachment(src, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        if session == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) }
        if w != width || h != height { pool = PixelBufferFactory.makePool(width: w, height: h); width = w; height = h }
        var dst: CVPixelBuffer?
        guard let session, let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst) == kCVReturnSuccess,
              let dst, VTPixelTransferSessionTransferImage(session, from: src, to: dst) == noErr else { return nil }
        return dst
    }
}
#endif
