import SwiftUI
import MetalKit

struct MetalPreviewView: NSViewRepresentable {
    let renderer: MetalRenderer
    var pipeline: MediaPipeline

    func makeNSView(context: Context) -> InteractiveMTKView {
        let mtkView = InteractiveMTKView()
        renderer.configure(view: mtkView)
        mtkView.delegate = renderer
        mtkView.coordinator = context.coordinator
        let coord = context.coordinator
        renderer.onBeforeDraw = { [weak coord] in
            coord?.refreshSelections()
        }
        return mtkView
    }

    func updateNSView(_ nsView: InteractiveMTKView, context: Context) {
        let coord = context.coordinator
        coord.pipeline = pipeline

        if coord.selectedSourceId != pipeline.selectedCanvasSourceId {
            coord.selectedSourceId = pipeline.selectedCanvasSourceId
            coord.updateSourceSelectionBorder()
        } else if coord.selectedSourceId != nil {
            coord.updateSourceSelectionBorder()
        }

        if coord.selectedOverlayId != nil {
            coord.updateOverlaySelectionBorder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(pipeline: pipeline)
    }

    enum DragMode {
        case none
        case overlayMove(UUID)
        case overlayResize(UUID, Edge)
        case canvasSourceMove(UUID)
        case canvasSourceResize(UUID, Edge)
        case canvasSourceCrop(UUID, Edge)
    }

    enum Edge {
        case left, right, top, bottom
        case topLeft, topRight, bottomLeft, bottomRight
    }

    @MainActor class Coordinator {
        var pipeline: MediaPipeline
        var outputSize: CGSize { pipeline.metalCompositor.outputSize }

        var dragMode: DragMode = .none
        var dragStart: CGPoint = .zero

        var startOverlayX: CGFloat = 0
        var startOverlayY: CGFloat = 0
        var startOverlayWidth: CGFloat = 0
        var startOverlayHeight: CGFloat = 0
        var selectedOverlayId: UUID?

        var selectedSourceId: UUID?
        var startSourceX: CGFloat = 0
        var startSourceY: CGFloat = 0
        var startSourceWidth: CGFloat = 0
        var startSourceHeight: CGFloat = 0
        var startSourceCropLeft: CGFloat = 0
        var startSourceCropRight: CGFloat = 0
        var startSourceCropTop: CGFloat = 0
        var startSourceCropBottom: CGFloat = 0
        var startRenderedRect: CGRect?
        var startOverlayRenderedRect: CGRect?

        private let overlayEdgeThreshold: CGFloat = 12
        private let sourceEdgeThreshold: CGFloat = 10

        init(pipeline: MediaPipeline) {
            self.pipeline = pipeline
        }

        func refreshSelections() {
            if selectedOverlayId != nil {
                updateOverlaySelectionBorder()
            }
            if selectedSourceId != nil {
                updateSourceSelectionBorder()
            }
        }

        func viewToCanvas(_ point: CGPoint, viewSize: CGSize) -> CGPoint? {
            let outAspect = outputSize.width / outputSize.height
            let viewAspect = viewSize.width / max(viewSize.height, 1)

            let renderW: CGFloat
            let renderH: CGFloat
            if outAspect > viewAspect {
                renderW = viewSize.width
                renderH = viewSize.width / outAspect
            } else {
                renderH = viewSize.height
                renderW = viewSize.height * outAspect
            }

            let offX = (viewSize.width - renderW) / 2
            let offY = (viewSize.height - renderH) / 2

            var cx = (point.x - offX) / renderW * outputSize.width
            var cy = (point.y - offY) / renderH * outputSize.height

            if cx < 0 || cx > outputSize.width || cy < 0 || cy > outputSize.height {
                return nil
            }

            let ps = CGFloat(pipeline.metalCompositor.currentPaddingScale)
            if ps < 1.0 {
                let centerX = outputSize.width / 2.0
                let centerY = outputSize.height / 2.0
                cx = centerX + (cx - centerX) / ps
                cy = centerY + (cy - centerY) / ps
            }

            return CGPoint(x: cx, y: cy)
        }

        func cursorFor(edge: Edge?) -> NSCursor {
            guard let edge = edge else { return .openHand }
            switch edge {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            case .topLeft, .bottomRight, .topRight, .bottomLeft: return .crosshair
            }
        }

        // MARK: - Overlay hit-testing

        func overlayRect(for overlay: StreamOverlay) -> CGRect {
            if let rect = pipeline.metalCompositor.renderedOverlayRects[overlay.id] {
                return rect
            }
            let canvas = outputSize
            return CGRect(x: overlay.x * canvas.width, y: overlay.y * canvas.height,
                          width: overlay.width * canvas.width, height: overlay.height * canvas.height)
        }

        func hitTestOverlay(_ canvasPoint: CGPoint) -> (overlay: StreamOverlay, edge: Edge?)? {
            let visibleOverlays = pipeline.overlays.filter { $0.isVisible }
            let t = overlayEdgeThreshold

            for overlay in visibleOverlays.reversed() {
                let rect = overlayRect(for: overlay)

                let nearLeft = abs(canvasPoint.x - rect.minX) < t && canvasPoint.y >= rect.minY - t && canvasPoint.y <= rect.maxY + t
                let nearRight = abs(canvasPoint.x - rect.maxX) < t && canvasPoint.y >= rect.minY - t && canvasPoint.y <= rect.maxY + t
                let nearTop = abs(canvasPoint.y - rect.minY) < t && canvasPoint.x >= rect.minX - t && canvasPoint.x <= rect.maxX + t
                let nearBottom = abs(canvasPoint.y - rect.maxY) < t && canvasPoint.x >= rect.minX - t && canvasPoint.x <= rect.maxX + t

                if nearLeft && nearTop { return (overlay, .topLeft) }
                if nearRight && nearTop { return (overlay, .topRight) }
                if nearLeft && nearBottom { return (overlay, .bottomLeft) }
                if nearRight && nearBottom { return (overlay, .bottomRight) }

                if nearRight { return (overlay, .right) }
                if nearLeft { return (overlay, .left) }
                if nearBottom { return (overlay, .bottom) }
                if nearTop { return (overlay, .top) }

                if rect.contains(canvasPoint) {
                    return (overlay, nil)
                }
            }
            return nil
        }

        // MARK: - Canvas source hit-testing

        func sourceRect(for source: CanvasSource) -> CGRect {
            if let rect = pipeline.metalCompositor.renderedSourceRects[source.id] {
                return rect
            }
            let canvas = outputSize
            return CGRect(x: source.x * canvas.width, y: source.y * canvas.height,
                          width: source.width * canvas.width, height: source.height * canvas.height)
        }

        func hitTestCanvasSource(_ canvasPoint: CGPoint) -> (source: CanvasSource, edge: Edge?)? {
            // Locked sources are non-interactive in the preview - clicks pass
            // straight through them. They're still rendered, just not editable.
            let visibleSources = pipeline.canvasSources
                .filter { $0.isVisible && !$0.isLocked }
                .sorted { $0.zOrder > $1.zOrder }
            let t = sourceEdgeThreshold

            for source in visibleSources {
                let rect = sourceRect(for: source)

                let nearLeft = abs(canvasPoint.x - rect.minX) < t
                let nearRight = abs(canvasPoint.x - rect.maxX) < t
                let nearTop = abs(canvasPoint.y - rect.minY) < t
                let nearBottom = abs(canvasPoint.y - rect.maxY) < t
                let inXRange = canvasPoint.x > rect.minX - t && canvasPoint.x < rect.maxX + t
                let inYRange = canvasPoint.y > rect.minY - t && canvasPoint.y < rect.maxY + t

                if nearTop && nearLeft && inXRange && inYRange { return (source, .topLeft) }
                if nearTop && nearRight && inXRange && inYRange { return (source, .topRight) }
                if nearBottom && nearLeft && inXRange && inYRange { return (source, .bottomLeft) }
                if nearBottom && nearRight && inXRange && inYRange { return (source, .bottomRight) }
                if nearRight && inYRange { return (source, .right) }
                if nearBottom && inXRange { return (source, .bottom) }
                if nearLeft && inYRange { return (source, .left) }
                if nearTop && inXRange { return (source, .top) }

                if rect.contains(canvasPoint) {
                    return (source, nil)
                }
            }
            return nil
        }

        func updateSourceSelectionBorder() {
            guard let id = selectedSourceId else {
                pipeline.renderer.selectionBorderFrame = nil
                return
            }

            guard let rawRect = pipeline.metalCompositor.renderedSourceRects[id] else {
                pipeline.renderer.selectionBorderFrame = nil
                return
            }

            let canvas = outputSize
            // The compositor stores the rect in un-padded canvas coordinates, but the rendered
            // quad shrinks toward the center by the padding scale. Apply the same transform so
            // the selection border hugs the rendered pixels.
            let ps = CGFloat(pipeline.metalCompositor.currentPaddingScale)
            let centerX = canvas.width / 2.0
            let centerY = canvas.height / 2.0
            let scaledOriginX = centerX + (rawRect.origin.x - centerX) * ps
            let scaledOriginY = centerY + (rawRect.origin.y - centerY) * ps
            let scaledW = rawRect.width * ps
            let scaledH = rawRect.height * ps
            let rect = CGRect(x: scaledOriginX, y: scaledOriginY, width: scaledW, height: scaledH)

            let ndcX = Float(rect.origin.x / canvas.width * 2.0 - 1.0)
            let ndcY = Float(1.0 - (rect.origin.y + rect.height) / canvas.height * 2.0)
            let ndcW = Float(rect.width / canvas.width * 2.0)
            let ndcH = Float(rect.height / canvas.height * 2.0)

            pipeline.renderer.selectionBorderFrame = SIMD4<Float>(ndcX, ndcY, ndcW, ndcH)
            pipeline.renderer.selectionBorderPixelSize = SIMD2<Float>(Float(rect.width), Float(rect.height))
            let source = pipeline.canvasSources.first(where: { $0.id == id })
            // The compositor enforces max(source.cornerRadius, canvas.cornerRadius)
            // when padding is applied, so mirror that for the selection border too.
            let baseRadius = Float(source?.cornerRadius ?? 0)
            let canvasRadius = Float(pipeline.metalCompositor.canvasConfig.cornerRadius)
            let appliedRadius = ps < 1.0 ? max(baseRadius, canvasRadius) : baseRadius
            pipeline.renderer.selectionBorderRadius = appliedRadius
        }


        // MARK: - Mouse events

        func mouseDown(at viewPoint: CGPoint, viewSize: CGSize, isAlt: Bool) {
            guard let cp = viewToCanvas(viewPoint, viewSize: viewSize) else { return }

            if let hit = hitTestOverlay(cp) {
                dragStart = cp
                startOverlayX = hit.overlay.x
                startOverlayY = hit.overlay.y
                startOverlayWidth = hit.overlay.width
                startOverlayHeight = hit.overlay.height
                startOverlayRenderedRect = pipeline.metalCompositor.renderedOverlayRects[hit.overlay.id]
                selectedOverlayId = hit.overlay.id
                updateOverlaySelectionBorder()
                DispatchQueue.main.async { self.pipeline.requestedSidebarTab = "overlays" }

                pipeline.isOverlayDragging = true
                if let edge = hit.edge {
                    dragMode = .overlayResize(hit.overlay.id, edge)
                } else {
                    dragMode = .overlayMove(hit.overlay.id)
                }
                return
            }

            if selectedOverlayId != nil {
                selectedOverlayId = nil
                pipeline.renderer.selectionBorderFrame = nil
            }

            if let hit = hitTestCanvasSource(cp) {
                selectedSourceId = hit.source.id
                pipeline.selectedCanvasSourceId = hit.source.id
                updateSourceSelectionBorder()
                DispatchQueue.main.async { self.pipeline.requestedSidebarTab = "sources" }

                if hit.source.isLocked {
                    dragMode = .none
                    return
                }

                dragStart = cp
                startSourceX = hit.source.x
                startSourceY = hit.source.y
                startSourceWidth = hit.source.width
                startSourceHeight = hit.source.height
                startSourceCropLeft = hit.source.cropLeft
                startSourceCropRight = hit.source.cropRight
                startSourceCropTop = hit.source.cropTop
                startSourceCropBottom = hit.source.cropBottom
                startRenderedRect = pipeline.metalCompositor.renderedSourceRects[hit.source.id]

                pipeline.isCanvasDragging = true

                let supportsCrop = hit.source.type == .camera || hit.source.type == .screenCapture || hit.source.type == .mediaFile
                if isAlt, let edge = hit.edge, supportsCrop {
                    dragMode = .canvasSourceCrop(hit.source.id, edge)
                } else if let edge = hit.edge {
                    dragMode = .canvasSourceResize(hit.source.id, edge)
                } else {
                    dragMode = .canvasSourceMove(hit.source.id)
                }
                return
            }

            if selectedSourceId != nil {
                selectedSourceId = nil
                pipeline.selectedCanvasSourceId = nil
                pipeline.renderer.selectionBorderFrame = nil
            }
        }

        func mouseDragged(to viewPoint: CGPoint, viewSize: CGSize) {
            if case .none = dragMode { return }
            guard let cp = viewToCanvas(viewPoint, viewSize: viewSize) else { return }

            let dx = cp.x - dragStart.x
            let dy = cp.y - dragStart.y

            switch dragMode {
            case .overlayMove(let id):
                guard let idx = pipeline.overlays.firstIndex(where: { $0.id == id }) else { return }
                let ndx = dx / outputSize.width
                let ndy = dy / outputSize.height
                pipeline.overlays[idx].x = clamp(startOverlayX + ndx, 0, 1 - pipeline.overlays[idx].width)
                pipeline.overlays[idx].y = clamp(startOverlayY + ndy, 0, 0.95)
                pipeline.syncOverlays()
                updateOverlaySelectionBorder()
                return

            case .overlayResize(let id, let edge):
                guard let idx = pipeline.overlays.firstIndex(where: { $0.id == id }) else { return }
                let ndx = dx / outputSize.width
                let ndy = dy / outputSize.height

                let overlayType = pipeline.overlays[idx].type
                // Only image and media have a fixed source aspect ratio needing fit-offset
                // compensation. Text, chat and captions fill their rect directly.
                let lockAspect = (overlayType == .image || overlayType == .media)

                var newWidth = startOverlayWidth
                var newHeight = startOverlayHeight
                var newX = startOverlayX
                var newY = startOverlayY

                switch edge {
                case .right:
                    newWidth = clamp(startOverlayWidth + ndx, 0.05, 0.95)
                case .left:
                    newWidth = clamp(startOverlayWidth - ndx, 0.05, 0.95)
                    newX = startOverlayX + (startOverlayWidth - newWidth)
                case .bottom:
                    newHeight = clamp(startOverlayHeight + ndy, 0.03, 0.95)
                case .top:
                    newHeight = clamp(startOverlayHeight - ndy, 0.03, 0.95)
                    newY = startOverlayY + (startOverlayHeight - newHeight)
                case .bottomRight, .bottomLeft, .topRight, .topLeft:
                    let widensRight = (edge == .bottomRight || edge == .topRight)
                    if widensRight {
                        newWidth = clamp(startOverlayWidth + ndx, 0.05, 0.95)
                    } else {
                        newWidth = clamp(startOverlayWidth - ndx, 0.05, 0.95)
                    }
                    if lockAspect {
                        let aspect = startOverlayHeight / max(startOverlayWidth, 0.01)
                        newHeight = clamp(newWidth * aspect, 0.03, 0.95)
                    } else {
                        let heightensDown = (edge == .bottomRight || edge == .bottomLeft)
                        if heightensDown {
                            newHeight = clamp(startOverlayHeight + ndy, 0.03, 0.95)
                        } else {
                            newHeight = clamp(startOverlayHeight - ndy, 0.03, 0.95)
                        }
                    }
                    if edge == .topLeft || edge == .topRight {
                        newY = startOverlayY + (startOverlayHeight - newHeight)
                    }
                    if edge == .topLeft || edge == .bottomLeft {
                        newX = startOverlayX + (startOverlayWidth - newWidth)
                    }
                }

                // Without this, anchoring the opposite edge drifts because aspect-fitted content
                // recenters inside the bounding box.
                if lockAspect, let rendered = startOverlayRenderedRect {
                    let canvas = outputSize
                    let texAspect = rendered.width / max(rendered.height, 1)

                    func fitOffset(destW: CGFloat, destH: CGFloat) -> (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
                        let rectAspect = destW / max(destH, 1)
                        let fitW: CGFloat
                        let fitH: CGFloat
                        if texAspect > rectAspect {
                            fitW = destW; fitH = destW / texAspect
                        } else {
                            fitH = destH; fitW = destH * texAspect
                        }
                        return ((destW - fitW) / 2, (destH - fitH) / 2, fitW, fitH)
                    }

                    let startFit = fitOffset(destW: startOverlayWidth * canvas.width, destH: startOverlayHeight * canvas.height)
                    let newFit = fitOffset(destW: newWidth * canvas.width, destH: newHeight * canvas.height)

                    let anchorsRight = edge == .left || edge == .topLeft || edge == .bottomLeft
                    let anchorsBottom = edge == .top || edge == .topLeft || edge == .topRight

                    if anchorsRight {
                        let anchor = startOverlayX * canvas.width + startFit.x + startFit.w
                        newX = (anchor - newFit.x - newFit.w) / canvas.width
                    } else {
                        let anchor = startOverlayX * canvas.width + startFit.x
                        newX = (anchor - newFit.x) / canvas.width
                    }

                    if anchorsBottom {
                        let anchor = startOverlayY * canvas.height + startFit.y + startFit.h
                        newY = (anchor - newFit.y - newFit.h) / canvas.height
                    } else {
                        let anchor = startOverlayY * canvas.height + startFit.y
                        newY = (anchor - newFit.y) / canvas.height
                    }
                }

                pipeline.overlays[idx].x = newX
                pipeline.overlays[idx].y = newY
                pipeline.overlays[idx].width = newWidth
                pipeline.overlays[idx].height = newHeight
                pipeline.syncOverlays()
                updateOverlaySelectionBorder()
                return

            case .canvasSourceMove(let id):
                guard let idx = pipeline.canvasSources.firstIndex(where: { $0.id == id }) else { return }
                let ndx = dx / outputSize.width
                let ndy = dy / outputSize.height
                let newX = clamp(startSourceX + ndx, -0.5, 1.5)
                let newY = clamp(startSourceY + ndy, -0.5, 1.5)

                pipeline.canvasSources[idx].x = newX
                pipeline.canvasSources[idx].y = newY
                pipeline.syncCanvasSources()
                updateSourceSelectionBorder()
                return

            case .canvasSourceResize(let id, let edge):
                guard let idx = pipeline.canvasSources.firstIndex(where: { $0.id == id }) else { return }
                let ndx = dx / outputSize.width
                let ndy = dy / outputSize.height

                var newWidth = startSourceWidth
                var newHeight = startSourceHeight
                var newX = startSourceX
                var newY = startSourceY

                switch edge {
                case .right:
                    newWidth = clamp(startSourceWidth + ndx, 0.05, 2.0)
                case .left:
                    newWidth = clamp(startSourceWidth - ndx, 0.05, 2.0)
                    newX = startSourceX + (startSourceWidth - newWidth)
                case .bottom:
                    newHeight = clamp(startSourceHeight + ndy, 0.05, 2.0)
                case .top:
                    newHeight = clamp(startSourceHeight - ndy, 0.05, 2.0)
                    newY = startSourceY + (startSourceHeight - newHeight)
                case .bottomRight:
                    newWidth = clamp(startSourceWidth + ndx, 0.05, 2.0)
                    newHeight = clamp(startSourceHeight + ndy, 0.05, 2.0)
                case .topLeft:
                    newWidth = clamp(startSourceWidth - ndx, 0.05, 2.0)
                    newHeight = clamp(startSourceHeight - ndy, 0.05, 2.0)
                    newX = startSourceX + (startSourceWidth - newWidth)
                    newY = startSourceY + (startSourceHeight - newHeight)
                case .topRight:
                    newWidth = clamp(startSourceWidth + ndx, 0.05, 2.0)
                    newHeight = clamp(startSourceHeight - ndy, 0.05, 2.0)
                    newY = startSourceY + (startSourceHeight - newHeight)
                case .bottomLeft:
                    newWidth = clamp(startSourceWidth - ndx, 0.05, 2.0)
                    newHeight = clamp(startSourceHeight + ndy, 0.05, 2.0)
                    newX = startSourceX + (startSourceWidth - newWidth)
                }

                if edge == .bottomRight || edge == .topLeft || edge == .topRight || edge == .bottomLeft {
                    let aspect = startSourceHeight / max(startSourceWidth, 0.01)
                    newHeight = newWidth * aspect
                    if edge == .topLeft || edge == .topRight {
                        newY = startSourceY + (startSourceHeight - newHeight)
                    }
                    if edge == .bottomLeft {
                        newX = startSourceX + (startSourceWidth - newWidth)
                    }
                }

                // Compensate for aspect-fit centering and crop offsets so the
                // rendered content's anchor corner stays fixed during resize.
                if let rendered = startRenderedRect {
                    let canvas = outputSize
                    let source = pipeline.canvasSources[idx]

                    let cL = startSourceCropLeft
                    let cR = startSourceCropRight
                    let cT = startSourceCropTop
                    let cB = startSourceCropBottom
                    let hasCrop = cL > 0 || cR > 0 || cT > 0 || cB > 0

                    let texAspect: CGFloat
                    if hasCrop {
                        let uncroppedW = rendered.width / max(1 - cL - cR, 0.01)
                        let uncroppedH = rendered.height / max(1 - cT - cB, 0.01)
                        texAspect = uncroppedW / max(uncroppedH, 1)
                    } else {
                        texAspect = rendered.width / max(rendered.height, 1)
                    }

                    func fitResult(destW: CGFloat, destH: CGFloat) -> (offX: CGFloat, offY: CGFloat, fitW: CGFloat, fitH: CGFloat) {
                        let rectAspect = destW / max(destH, 1)
                        let fitW: CGFloat
                        let fitH: CGFloat
                        if texAspect > rectAspect {
                            fitW = destW; fitH = destW / texAspect
                        } else {
                            fitH = destH; fitW = destH * texAspect
                        }
                        return ((destW - fitW) / 2, (destH - fitH) / 2, fitW, fitH)
                    }

                    let startFit = fitResult(destW: startSourceWidth * canvas.width, destH: startSourceHeight * canvas.height)
                    let newFit = fitResult(destW: newWidth * canvas.width, destH: newHeight * canvas.height)

                    let mirror = source.isMirrored && source.type == .camera
                    let effectiveCL = mirror ? cR : cL
                    let effectiveCR = mirror ? cL : cR

                    let anchorsRight = edge == .left || edge == .topLeft || edge == .bottomLeft
                    let anchorsBottom = edge == .top || edge == .topLeft || edge == .topRight

                    if anchorsRight {
                        let startAnchorX = startSourceX * canvas.width + startFit.offX + startFit.fitW * (1 - effectiveCR)
                        newX = (startAnchorX - newFit.offX - newFit.fitW * (1 - effectiveCR)) / canvas.width
                    } else {
                        let startAnchorX = startSourceX * canvas.width + startFit.offX + startFit.fitW * effectiveCL
                        newX = (startAnchorX - newFit.offX - newFit.fitW * effectiveCL) / canvas.width
                    }

                    if anchorsBottom {
                        let startAnchorY = startSourceY * canvas.height + startFit.offY + startFit.fitH * (1 - cB)
                        newY = (startAnchorY - newFit.offY - newFit.fitH * (1 - cB)) / canvas.height
                    } else {
                        let startAnchorY = startSourceY * canvas.height + startFit.offY + startFit.fitH * cT
                        newY = (startAnchorY - newFit.offY - newFit.fitH * cT) / canvas.height
                    }
                }

                pipeline.canvasSources[idx].x = newX
                pipeline.canvasSources[idx].y = newY
                pipeline.canvasSources[idx].width = newWidth
                pipeline.canvasSources[idx].height = newHeight
                pipeline.syncCanvasSources()
                updateSourceSelectionBorder()
                return

            case .canvasSourceCrop(let id, let edge):
                guard let idx = pipeline.canvasSources.firstIndex(where: { $0.id == id }) else { return }
                let isMirrored = pipeline.canvasSources[idx].isMirrored && pipeline.canvasSources[idx].type == .camera
                let result = applyCrop(
                    edge: edge, dx: dx, dy: dy,
                    startCrop: CropValues(cropLeft: startSourceCropLeft, cropRight: startSourceCropRight, cropTop: startSourceCropTop, cropBottom: startSourceCropBottom),
                    isMirrored: isMirrored
                )
                pipeline.canvasSources[idx].cropLeft = result.cropLeft
                pipeline.canvasSources[idx].cropRight = result.cropRight
                pipeline.canvasSources[idx].cropTop = result.cropTop
                pipeline.canvasSources[idx].cropBottom = result.cropBottom
                pipeline.syncCanvasSources()
                updateSourceSelectionBorder()
                return

            case .none:
                return
            }
        }

        func mouseUp() {
            if case .none = dragMode { return }

            switch dragMode {
            case .overlayMove, .overlayResize:
                pipeline.isOverlayDragging = false
                Persistence.saveOverlays(pipeline.overlays)
            case .canvasSourceMove, .canvasSourceResize, .canvasSourceCrop:
                pipeline.isCanvasDragging = false
                pipeline.persistCanvasSources()
            case .none:
                break
            }
            dragMode = .none
        }

        func mouseMoved(at viewPoint: CGPoint, viewSize: CGSize) {
            guard let cp = viewToCanvas(viewPoint, viewSize: viewSize) else {
                NSCursor.arrow.set()
                return
            }

            if let hit = hitTestOverlay(cp) {
                if let edge = hit.edge {
                    cursorFor(edge: edge).set()
                } else {
                    NSCursor.openHand.set()
                }
                return
            }

            if let hit = hitTestCanvasSource(cp) {
                if let edge = hit.edge {
                    cursorFor(edge: edge).set()
                } else {
                    NSCursor.openHand.set()
                }
                return
            }

            NSCursor.arrow.set()
        }

        func updateOverlaySelectionBorder() {
            guard let id = selectedOverlayId else {
                pipeline.renderer.selectionBorderFrame = nil
                return
            }

            let rect: CGRect
            if let rendered = pipeline.metalCompositor.renderedOverlayRects[id] {
                rect = rendered
            } else if let overlay = pipeline.overlays.first(where: { $0.id == id }) {
                rect = overlayRect(for: overlay)
            } else {
                pipeline.renderer.selectionBorderFrame = nil
                return
            }

            let canvas = outputSize
            let ndcX = Float(rect.origin.x / canvas.width * 2.0 - 1.0)
            let ndcY = Float(1.0 - (rect.origin.y + rect.height) / canvas.height * 2.0)
            let ndcW = Float(rect.width / canvas.width * 2.0)
            let ndcH = Float(rect.height / canvas.height * 2.0)

            pipeline.renderer.selectionBorderFrame = SIMD4<Float>(ndcX, ndcY, ndcW, ndcH)
            pipeline.renderer.selectionBorderPixelSize = SIMD2<Float>(Float(rect.width), Float(rect.height))
            pipeline.renderer.selectionBorderRadius = 6
        }

        // MARK: - Keyboard

        func handleKeyDown(_ event: NSEvent) {
            let isDelete = event.keyCode == 51 || event.keyCode == 117
            let isArrow = [123, 124, 125, 126].contains(event.keyCode)

            if let overlayId = selectedOverlayId, isDelete {
                pipeline.removeOverlay(overlayId)
                selectedOverlayId = nil
                pipeline.renderer.selectionBorderFrame = nil
                return
            }

            if let overlayId = selectedOverlayId, isArrow,
               let idx = pipeline.overlays.firstIndex(where: { $0.id == overlayId }) {
                let step: CGFloat = event.modifierFlags.contains(.shift) ? 0.005 : 0.02
                switch event.keyCode {
                case 123: pipeline.overlays[idx].x -= step
                case 124: pipeline.overlays[idx].x += step
                case 126: pipeline.overlays[idx].y -= step
                case 125: pipeline.overlays[idx].y += step
                default: break
                }
                pipeline.syncOverlays()
                updateOverlaySelectionBorder()
                return
            }

            guard let id = selectedSourceId,
                  let idx = pipeline.canvasSources.firstIndex(where: { $0.id == id }) else {
                return
            }

            let source = pipeline.canvasSources[idx]

            if event.keyCode == 51 || event.keyCode == 117 {
                // Deleting the PiP camera switches to the Screen scene. The source stays on the
                // built-in canvas.
                if pipeline.activeCanvasId == Canvas.pipBuiltInId && source.type == .camera {
                    selectedSourceId = nil
                    pipeline.selectedCanvasSourceId = nil
                    pipeline.renderer.selectionBorderFrame = nil
                    Task { await pipeline.setCanvas(Canvas.screenBuiltInId) }
                    return
                }

                if !source.isLocked {
                    pipeline.removeCanvasSource(id)
                    selectedSourceId = nil
                    pipeline.selectedCanvasSourceId = nil
                    pipeline.renderer.selectionBorderFrame = nil
                }
                return
            }

            if source.isLocked { return }

            let step: CGFloat = event.modifierFlags.contains(.shift) ? 0.001 : 0.01

            switch event.keyCode {
            case 123:
                pipeline.canvasSources[idx].x -= step
                pipeline.syncCanvasSources()
                updateSourceSelectionBorder()
                pipeline.persistCanvasSources()
            case 124:
                pipeline.canvasSources[idx].x += step
                pipeline.syncCanvasSources()
                updateSourceSelectionBorder()
                pipeline.persistCanvasSources()
            case 126:
                pipeline.canvasSources[idx].y -= step
                pipeline.syncCanvasSources()
                updateSourceSelectionBorder()
                pipeline.persistCanvasSources()
            case 125:
                pipeline.canvasSources[idx].y += step
                pipeline.syncCanvasSources()
                updateSourceSelectionBorder()
                pipeline.persistCanvasSources()
            default:
                break
            }
        }

        struct CropValues {
            var cropLeft: CGFloat
            var cropRight: CGFloat
            var cropTop: CGFloat
            var cropBottom: CGFloat
        }

        private func applyCrop(
            edge: Edge,
            dx: CGFloat,
            dy: CGFloat,
            startCrop: CropValues,
            isMirrored: Bool
        ) -> CropValues {
            let maxCrop: CGFloat = 0.45
            let ndx = dx / outputSize.width * 2
            let ndy = dy / outputSize.height * 2
            var crop = startCrop

            func setCropLeft(_ delta: CGFloat) {
                if isMirrored {
                    crop.cropRight = clamp(startCrop.cropRight + delta, 0, maxCrop)
                } else {
                    crop.cropLeft = clamp(startCrop.cropLeft + delta, 0, maxCrop)
                }
            }
            func setCropRight(_ delta: CGFloat) {
                if isMirrored {
                    crop.cropLeft = clamp(startCrop.cropLeft - delta, 0, maxCrop)
                } else {
                    crop.cropRight = clamp(startCrop.cropRight - delta, 0, maxCrop)
                }
            }
            func setCropTop(_ delta: CGFloat) {
                crop.cropTop = clamp(startCrop.cropTop + delta, 0, maxCrop)
            }
            func setCropBottom(_ delta: CGFloat) {
                crop.cropBottom = clamp(startCrop.cropBottom - delta, 0, maxCrop)
            }

            switch edge {
            case .left:       setCropLeft(ndx)
            case .right:      setCropRight(ndx)
            case .top:        setCropTop(ndy)
            case .bottom:     setCropBottom(ndy)
            case .topLeft:    setCropLeft(ndx); setCropTop(ndy)
            case .topRight:   setCropRight(ndx); setCropTop(ndy)
            case .bottomLeft: setCropLeft(ndx); setCropBottom(ndy)
            case .bottomRight: setCropRight(ndx); setCropBottom(ndy)
            }

            return crop
        }

        private func clamp(_ value: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            max(lo, min(hi, value))
        }
    }
}

class InteractiveMTKView: MTKView {
    weak var coordinator: MetalPreviewView.Coordinator?
    private var localDragMonitor: Any?
    private var globalDragMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let scale = window?.backingScaleFactor else { return }
        (layer as? CAMetalLayer)?.contentsScale = scale
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: point.x, y: bounds.height - point.y)
        coordinator?.mouseMoved(at: flipped, viewSize: bounds.size)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    private func screenPointToView(_ screenPoint: CGPoint) -> CGPoint {
        guard let window = self.window else { return .zero }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let viewPoint = convert(windowPoint, from: nil)
        return CGPoint(x: viewPoint.x, y: bounds.height - viewPoint.y)
    }

    private func removeDragMonitors() {
        if let monitor = localDragMonitor {
            NSEvent.removeMonitor(monitor)
            localDragMonitor = nil
        }
        if let monitor = globalDragMonitor {
            NSEvent.removeMonitor(monitor)
            globalDragMonitor = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: point.x, y: bounds.height - point.y)
        coordinator?.mouseDown(at: flipped, viewSize: bounds.size, isAlt: event.modifierFlags.contains(.option))

        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            let flipped = CGPoint(x: point.x, y: self.bounds.height - point.y)
            if event.type == .leftMouseDragged {
                self.coordinator?.mouseDragged(to: flipped, viewSize: self.bounds.size)
            } else {
                self.coordinator?.mouseUp()
                self.removeDragMonitors()
            }
            return event
        }

        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return }
            let flipped = self.screenPointToView(NSEvent.mouseLocation)
            if event.type == .leftMouseDragged {
                self.coordinator?.mouseDragged(to: flipped, viewSize: self.bounds.size)
            } else {
                self.coordinator?.mouseUp()
                self.removeDragMonitors()
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {}

    override func keyDown(with event: NSEvent) {
        let arrowKeys: Set<UInt16> = [123, 124, 125, 126]
        let deleteKeys: Set<UInt16> = [51, 117]
        if arrowKeys.contains(event.keyCode) || deleteKeys.contains(event.keyCode) {
            coordinator?.handleKeyDown(event)
        }
    }
}
