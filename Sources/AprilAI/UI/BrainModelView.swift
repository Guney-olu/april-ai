import AppKit
import Foundation
import SceneKit
import SwiftUI

struct MemoryBrainSignal: Identifiable, Equatable {
    let id: String
    let title: String
    let memoryCount: Int
}

enum MemoryBrainPalette {
    static func swiftUIColor(for id: String) -> Color {
        Color(nsColor: nsColor(for: id))
    }

    static func nsColor(for id: String) -> NSColor {
        let hash = abs(id.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) })
        let hue = CGFloat(hash % 360) / 360.0
        return NSColor(calibratedHue: hue, saturation: 0.62, brightness: 1.0, alpha: 1.0)
    }
}

struct BrainModelView: NSViewRepresentable {
    let signals: [MemoryBrainSignal]
    let totalSessionCount: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SCNView {
        let view = BrainSceneView()
        view.onInteraction = {
            context.coordinator.markUserInteraction()
        }
        context.coordinator.configure(view: view)
        context.coordinator.update(signals: signals, totalSessionCount: totalSessionCount)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.update(signals: signals, totalSessionCount: totalSessionCount)
        view.isPlaying = true
    }

    @MainActor
    final class Coordinator {
        private weak var view: SCNView?
        private var components: BrainSceneComponents?
        private var visibleSignalKey = ""
        private var lastInteractionDate = Date.distantPast
        private var interactionGeneration = 0

        func configure(view: SCNView) {
            let components = BrainSceneFactory.makeScene()
            self.view = view
            self.components = components

            view.scene = components.scene
            view.backgroundColor = .clear
            view.allowsCameraControl = true
            view.autoenablesDefaultLighting = false
            view.antialiasingMode = .multisampling4X
            view.rendersContinuously = true
            view.isPlaying = true

            view.defaultCameraController.inertiaEnabled = true
            view.defaultCameraController.interactionMode = .orbitTurntable

        }

        func markUserInteraction() {
            lastInteractionDate = Date()
            interactionGeneration += 1
            let generation = interactionGeneration
            refreshIdleSpeed()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                guard let self, self.interactionGeneration == generation else { return }
                self.refreshIdleSpeed()
            }
        }

        func update(signals: [MemoryBrainSignal], totalSessionCount: Int) {
            guard let components else { return }
            let visibleSignals = Array(signals.prefix(8))
            let signalKey = visibleSignals
                .map { "\($0.id):\($0.memoryCount)" }
                .joined(separator: "|") + "|total:\(totalSessionCount)"

            guard signalKey != visibleSignalKey else { return }
            visibleSignalKey = signalKey

            components.wireRoot.childNodes.forEach { $0.removeFromParentNode() }
            guard !visibleSignals.isEmpty else { return }

            for (index, signal) in visibleSignals.enumerated() {
                let color = MemoryBrainPalette.nsColor(for: signal.id)
                let cluster = BrainWireFactory.cluster(
                    signal: signal,
                    index: index,
                    total: visibleSignals.count,
                    color: color
                )
                components.wireRoot.addChildNode(cluster)
            }

            if signals.count > visibleSignals.count {
                components.wireRoot.addChildNode(
                    BrainWireFactory.overflowHalo(hiddenCount: signals.count - visibleSignals.count)
                )
            }
        }

        private func refreshIdleSpeed() {
            guard let components else { return }
            let isInteracting = Date().timeIntervalSince(lastInteractionDate) < 2.2
            components.orbitNode.action(forKey: "idle-orbit")?.speed = isInteracting ? 0.12 : 1.0
            for node in components.wireRoot.childNodes {
                node.action(forKey: "wire-orbit")?.speed = isInteracting ? 0.2 : 1.0
            }
        }
    }
}

private final class BrainSceneView: SCNView {
    var onInteraction: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        onInteraction?()
        super.mouseDragged(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onInteraction?()
        super.rightMouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        onInteraction?()
        super.scrollWheel(with: event)
    }
}

private struct BrainSceneComponents {
    let scene: SCNScene
    let orbitNode: SCNNode
    let wireRoot: SCNNode
}

private enum BrainSceneFactory {
    static func makeScene() -> BrainSceneComponents {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear

        let orbit = SCNNode()
        let model = modelNode() ?? fallbackNode()
        orbit.addChildNode(model)

        let wireRoot = SCNNode()
        wireRoot.name = "memory-wire-root"
        orbit.addChildNode(wireRoot)

        scene.rootNode.addChildNode(orbit)

        normalize(model)
        applyMemoryMaterial(to: model)

        let camera = SCNCamera()
        camera.fieldOfView = 36
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = true
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0.2, 4.2)
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNLight()
        key.type = .omni
        key.intensity = 980
        key.temperature = 6200
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(1.8, 2.2, 2.4)
        keyNode.runAction(.repeatForever(.sequence([
            .moveBy(x: -0.35, y: 0.18, z: 0.15, duration: 3.2),
            .moveBy(x: 0.35, y: -0.18, z: -0.15, duration: 3.2)
        ])))
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .ambient
        fill.intensity = 340
        fill.color = NSColor(calibratedRed: 0.45, green: 0.65, blue: 1.0, alpha: 1.0)
        let fillNode = SCNNode()
        fillNode.light = fill
        scene.rootNode.addChildNode(fillNode)

        orbit.runAction(.repeatForever(.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 26)), forKey: "idle-orbit")
        model.runAction(.repeatForever(.sequence([
            .moveBy(x: 0, y: 0.045, z: 0, duration: 2.8),
            .moveBy(x: 0, y: -0.045, z: 0, duration: 2.8)
        ])), forKey: "breathing-float")
        pulseMaterials(in: model)

        return BrainSceneComponents(scene: scene, orbitNode: orbit, wireRoot: wireRoot)
    }

    private static func modelNode() -> SCNNode? {
        guard let url = brainAssetURL() else { return nil }
        if let scene = try? SCNScene(url: url) {
            let root = SCNNode()
            for node in scene.rootNode.childNodes {
                root.addChildNode(node.clone())
            }
            return root.childNodes.isEmpty ? nil : root
        }

        if let node = try? SimpleGLBLoader.loadNode(from: url) {
            return node
        }

        return nil
    }

    private static func brainAssetURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "brain human", withExtension: "glb") {
            return bundled
        }

        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            workingDirectory.appending(path: "Assets/brain human.glb"),
            workingDirectory.deletingLastPathComponent().appending(path: "Assets/brain human.glb")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func fallbackNode() -> SCNNode {
        let root = SCNNode()

        let left = SCNSphere(radius: 0.72)
        left.segmentCount = 48
        let leftNode = SCNNode(geometry: left)
        leftNode.scale = SCNVector3(0.88, 1.0, 0.68)
        leftNode.position = SCNVector3(-0.38, 0, 0)

        let right = SCNSphere(radius: 0.72)
        right.segmentCount = 48
        let rightNode = SCNNode(geometry: right)
        rightNode.scale = SCNVector3(0.88, 1.0, 0.68)
        rightNode.position = SCNVector3(0.38, 0, 0)

        root.addChildNode(leftNode)
        root.addChildNode(rightNode)

        for index in 0..<9 {
            let tube = SCNTorus(ringRadius: 0.48 + CGFloat(index) * 0.035, pipeRadius: 0.012)
            tube.ringSegmentCount = 80
            tube.pipeSegmentCount = 8
            let node = SCNNode(geometry: tube)
            node.eulerAngles = SCNVector3(
                Float.random(in: -0.9...0.9),
                Float.random(in: -0.7...0.7),
                Float(index) * 0.42
            )
            node.position = SCNVector3(Float(index % 3 - 1) * 0.22, Float(index - 4) * 0.03, 0)
            root.addChildNode(node)
        }

        return root
    }

    private static func pulseMaterials(in node: SCNNode) {
        node.enumerateChildNodes { child, _ in
            guard child.geometry != nil else { return }
            child.runAction(.repeatForever(.sequence([
                .fadeOpacity(to: 0.84, duration: 1.8),
                .fadeOpacity(to: 1.0, duration: 1.8)
            ])), forKey: "emission-pulse")
        }
    }
}

private enum BrainWireFactory {
    static func cluster(signal: MemoryBrainSignal, index: Int, total: Int, color: NSColor) -> SCNNode {
        let root = SCNNode()
        root.name = "wire-\(signal.id)"

        let angle = (Double(index) / Double(max(total, 1))) * Double.pi * 2
        let y = Double(index % 3 - 1) * 0.34
        let startRadius = 0.68
        let endRadius = 1.42
        let start = SCNVector3(
            Float(cos(angle) * startRadius),
            Float(y * 0.38),
            Float(sin(angle) * startRadius)
        )
        let end = SCNVector3(
            Float(cos(angle + 0.36) * endRadius),
            Float(y),
            Float(sin(angle + 0.36) * endRadius)
        )
        let mid = SCNVector3(
            Float(cos(angle + 0.18) * 1.08),
            Float(y + 0.22 * sin(angle * 1.7)),
            Float(sin(angle + 0.18) * 1.08)
        )

        root.addChildNode(cylinder(from: start, to: mid, radius: 0.01, color: color, alpha: 0.72))
        root.addChildNode(cylinder(from: mid, to: end, radius: 0.01, color: color, alpha: 0.72))
        root.addChildNode(glowSphere(at: end, radius: 0.045, color: color, alpha: 0.92))

        let memoryNodeCount = min(max(signal.memoryCount, 1), 6)
        for memoryIndex in 0..<memoryNodeCount {
            let t = CGFloat(memoryIndex + 1) / CGFloat(memoryNodeCount + 1)
            let point = bezier(start, mid, end, t)
            let node = glowSphere(at: point, radius: 0.024, color: color, alpha: 0.84)
            let phase = Double(memoryIndex) * 0.33
            node.runAction(.repeatForever(.sequence([
                .scale(to: 1.32, duration: 0.8 + phase),
                .scale(to: 0.92, duration: 0.8)
            ])))
            root.addChildNode(node)
        }

        root.runAction(
            .repeatForever(.rotateBy(x: 0, y: 0.0, z: CGFloat.pi * 2, duration: 18 + Double(index))),
            forKey: "wire-orbit"
        )
        return root
    }

    static func overflowHalo(hiddenCount: Int) -> SCNNode {
        let root = SCNNode()
        root.name = "overflow-halo"

        let torus = SCNTorus(ringRadius: 1.62, pipeRadius: 0.01)
        torus.ringSegmentCount = 120
        torus.pipeSegmentCount = 8
        let material = glowMaterial(color: NSColor.systemPurple, alpha: 0.42)
        torus.firstMaterial = material

        let halo = SCNNode(geometry: torus)
        halo.eulerAngles = SCNVector3(Float.pi / 2.8, 0, Float.pi / 6)
        halo.runAction(.repeatForever(.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 16)))
        root.addChildNode(halo)

        let labelNode = glowSphere(at: SCNVector3(1.62, 0, 0), radius: min(0.09, 0.045 + CGFloat(hiddenCount) * 0.004), color: .systemPurple, alpha: 0.78)
        root.addChildNode(labelNode)
        return root
    }

    private static func bezier(_ a: SCNVector3, _ b: SCNVector3, _ c: SCNVector3, _ t: CGFloat) -> SCNVector3 {
        let u = 1 - t
        let ax = u * u * a.x + 2 * u * t * b.x + t * t * c.x
        let ay = u * u * a.y + 2 * u * t * b.y + t * t * c.y
        let az = u * u * a.z + 2 * u * t * b.z + t * t * c.z
        return SCNVector3(
            ax,
            ay,
            az
        )
    }

    private static func cylinder(from: SCNVector3, to: SCNVector3, radius: CGFloat, color: NSColor, alpha: CGFloat) -> SCNNode {
        let vector = to - from
        let length = CGFloat(vector.length)
        let geometry = SCNCylinder(radius: radius, height: length)
        geometry.radialSegmentCount = 10
        geometry.firstMaterial = glowMaterial(color: color, alpha: alpha)

        let node = SCNNode(geometry: geometry)
        node.position = (from + to) * 0.5
        node.orientation = SCNQuaternion.rotation(from: SCNVector3(0, 1, 0), to: vector.normalized)
        node.runAction(SCNAction.repeatForever(SCNAction.sequence([
            SCNAction.fadeOpacity(to: 0.55, duration: 1.2),
            SCNAction.fadeOpacity(to: 1.0, duration: 1.2)
        ])))
        return node
    }

    private static func glowSphere(at point: SCNVector3, radius: CGFloat, color: NSColor, alpha: CGFloat) -> SCNNode {
        let sphere = SCNSphere(radius: radius)
        sphere.segmentCount = 24
        sphere.firstMaterial = glowMaterial(color: color, alpha: alpha)
        let node = SCNNode(geometry: sphere)
        node.position = point
        return node
    }

    private static func glowMaterial(color: NSColor, alpha: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color.withAlphaComponent(alpha)
        material.emission.contents = color.withAlphaComponent(alpha)
        material.emission.intensity = 0.95
        material.isDoubleSided = true
        return material
    }
}

private enum SimpleGLBLoader {
    private static let jsonChunkType: UInt32 = 0x4E4F534A
    private static let binaryChunkType: UInt32 = 0x004E4942

    static func loadNode(from url: URL) throws -> SCNNode {
        let data = try Data(contentsOf: url)
        guard data.count >= 20,
              data.readUInt32(at: 0) == 0x46546C67,
              data.readUInt32(at: 4) == 2
        else {
            throw GLBError.invalidHeader
        }

        var offset = 12
        var jsonData: Data?
        var binaryData: Data?
        while offset + 8 <= data.count {
            let chunkLength = Int(data.readUInt32(at: offset))
            let chunkType = data.readUInt32(at: offset + 4)
            let chunkStart = offset + 8
            let chunkEnd = chunkStart + chunkLength
            guard chunkEnd <= data.count else { throw GLBError.invalidChunk }

            let chunk = data.subdata(in: chunkStart..<chunkEnd)
            if chunkType == jsonChunkType {
                jsonData = chunk
            } else if chunkType == binaryChunkType {
                binaryData = chunk
            }
            offset = chunkEnd
        }

        guard let jsonData, let binaryData else { throw GLBError.missingChunk }
        let gltf = try JSONDecoder().decode(GLTF.self, from: jsonData)
        let root = SCNNode()
        root.name = "brain human.glb"

        for mesh in gltf.meshes {
            for primitive in mesh.primitives where primitive.mode == nil || primitive.mode == 4 {
                if let geometry = try geometry(for: primitive, gltf: gltf, binaryData: binaryData) {
                    let node = SCNNode(geometry: geometry)
                    node.name = mesh.name
                    root.addChildNode(node)
                }
            }
        }

        guard !root.childNodes.isEmpty else { throw GLBError.emptyMesh }
        return root
    }

    private static func geometry(for primitive: GLTFPrimitive, gltf: GLTF, binaryData: Data) throws -> SCNGeometry? {
        guard let positionIndex = primitive.attributes["POSITION"],
              let indicesIndex = primitive.indices
        else {
            return nil
        }

        let positionAccessor = gltf.accessors[positionIndex]
        let positionData = try packedFloatAccessorData(positionAccessor, gltf: gltf, binaryData: binaryData, components: 3)
        let positionSource = SCNGeometrySource(
            data: positionData,
            semantic: .vertex,
            vectorCount: positionAccessor.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: 4,
            dataOffset: 0,
            dataStride: 12
        )

        var sources = [positionSource]
        if let normalIndex = primitive.attributes["NORMAL"] {
            let normalAccessor = gltf.accessors[normalIndex]
            let normalData = try packedFloatAccessorData(normalAccessor, gltf: gltf, binaryData: binaryData, components: 3)
            sources.append(SCNGeometrySource(
                data: normalData,
                semantic: .normal,
                vectorCount: normalAccessor.count,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: 4,
                dataOffset: 0,
                dataStride: 12
            ))
        }

        let indexAccessor = gltf.accessors[indicesIndex]
        let indexData = try packedIndexAccessorData(indexAccessor, gltf: gltf, binaryData: binaryData)
        let bytesPerIndex = bytesPerIndex(for: indexAccessor.componentType)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indexAccessor.count / 3,
            bytesPerIndex: bytesPerIndex
        )

        let geometry = SCNGeometry(sources: sources, elements: [element])
        geometry.firstMaterial = brainMaterial()
        return geometry
    }

    private static func packedFloatAccessorData(_ accessor: GLTFAccessor, gltf: GLTF, binaryData: Data, components: Int) throws -> Data {
        guard accessor.componentType == 5126,
              accessor.type == "VEC\(components)",
              let bufferViewIndex = accessor.bufferView
        else {
            throw GLBError.unsupportedAccessor
        }

        let bufferView = gltf.bufferViews[bufferViewIndex]
        let stride = bufferView.byteStride ?? components * 4
        let sourceStart = bufferView.byteOffset + (accessor.byteOffset ?? 0)
        var output = Data(count: accessor.count * components * 4)

        for index in 0..<accessor.count {
            let sourceOffset = sourceStart + index * stride
            let destinationOffset = index * components * 4
            guard sourceOffset + components * 4 <= binaryData.count else {
                throw GLBError.outOfBounds
            }
            output.replaceSubrange(
                destinationOffset..<(destinationOffset + components * 4),
                with: binaryData[sourceOffset..<(sourceOffset + components * 4)]
            )
        }

        return output
    }

    private static func packedIndexAccessorData(_ accessor: GLTFAccessor, gltf: GLTF, binaryData: Data) throws -> Data {
        guard accessor.type == "SCALAR",
              let bufferViewIndex = accessor.bufferView
        else {
            throw GLBError.unsupportedAccessor
        }

        let byteCount = bytesPerIndex(for: accessor.componentType)
        let bufferView = gltf.bufferViews[bufferViewIndex]
        let stride = bufferView.byteStride ?? byteCount
        let sourceStart = bufferView.byteOffset + (accessor.byteOffset ?? 0)
        var output = Data(count: accessor.count * byteCount)

        for index in 0..<accessor.count {
            let sourceOffset = sourceStart + index * stride
            let destinationOffset = index * byteCount
            guard sourceOffset + byteCount <= binaryData.count else {
                throw GLBError.outOfBounds
            }
            output.replaceSubrange(
                destinationOffset..<(destinationOffset + byteCount),
                with: binaryData[sourceOffset..<(sourceOffset + byteCount)]
            )
        }

        return output
    }

    private static func bytesPerIndex(for componentType: Int) -> Int {
        switch componentType {
        case 5121: 1
        case 5123: 2
        case 5125: 4
        default: 4
        }
    }

    private static func brainMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(calibratedRed: 0.72, green: 0.80, blue: 1.0, alpha: 1.0)
        material.emission.contents = NSColor(calibratedRed: 0.10, green: 0.28, blue: 0.58, alpha: 1.0)
        material.emission.intensity = 0.18
        material.metalness.contents = 0.05
        material.roughness.contents = 0.42
        return material
    }

    private struct GLTF: Decodable {
        let accessors: [GLTFAccessor]
        let bufferViews: [GLTFBufferView]
        let meshes: [GLTFMesh]
    }

    private struct GLTFAccessor: Decodable {
        let bufferView: Int?
        let byteOffset: Int?
        let componentType: Int
        let count: Int
        let type: String
    }

    private struct GLTFBufferView: Decodable {
        let byteOffset: Int
        let byteLength: Int
        let byteStride: Int?

        private enum CodingKeys: String, CodingKey {
            case byteOffset
            case byteLength
            case byteStride
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            byteOffset = try container.decodeIfPresent(Int.self, forKey: .byteOffset) ?? 0
            byteLength = try container.decode(Int.self, forKey: .byteLength)
            byteStride = try container.decodeIfPresent(Int.self, forKey: .byteStride)
        }
    }

    private struct GLTFMesh: Decodable {
        let name: String?
        let primitives: [GLTFPrimitive]
    }

    private struct GLTFPrimitive: Decodable {
        let attributes: [String: Int]
        let indices: Int?
        let mode: Int?
    }

    private enum GLBError: Error {
        case invalidHeader
        case invalidChunk
        case missingChunk
        case unsupportedAccessor
        case outOfBounds
        case emptyMesh
    }
}

private extension BrainSceneFactory {
    static func normalize(_ node: SCNNode) {
        let box = node.boundingBox
        let minPoint = box.min
        let maxPoint = box.max
        let width = maxPoint.x - minPoint.x
        let height = maxPoint.y - minPoint.y
        let depth = maxPoint.z - minPoint.z
        let largest = max(width, max(height, depth))
        guard largest > 0 else { return }

        node.pivot = SCNMatrix4MakeTranslation(
            minPoint.x + width / 2,
            minPoint.y + height / 2,
            minPoint.z + depth / 2
        )
        let scale = 1.9 / largest
        node.scale = SCNVector3(scale, scale, scale)
    }

    static func applyMemoryMaterial(to node: SCNNode) {
        node.enumerateChildNodes { child, _ in
            guard let geometry = child.geometry else { return }
            for material in geometry.materials where material.diffuse.contents == nil {
                material.lightingModel = .physicallyBased
                material.diffuse.contents = NSColor(calibratedRed: 0.72, green: 0.80, blue: 1.0, alpha: 1.0)
                material.emission.contents = NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.42, alpha: 1.0)
                material.emission.intensity = 0.22
                material.metalness.contents = 0.12
                material.roughness.contents = 0.45
            }
        }
    }
}

private extension SCNVector3 {
    static func + (left: SCNVector3, right: SCNVector3) -> SCNVector3 {
        SCNVector3(left.x + right.x, left.y + right.y, left.z + right.z)
    }

    static func - (left: SCNVector3, right: SCNVector3) -> SCNVector3 {
        SCNVector3(left.x - right.x, left.y - right.y, left.z - right.z)
    }

    static func * (vector: SCNVector3, scalar: CGFloat) -> SCNVector3 {
        SCNVector3(vector.x * scalar, vector.y * scalar, vector.z * scalar)
    }

    var length: CGFloat {
        let squared = x * x + y * y + z * z
        return sqrt(squared)
    }

    var normalized: SCNVector3 {
        let length = self.length
        guard length > 0 else { return SCNVector3(0, 1, 0) }
        return self * (1 / length)
    }
}

private extension SCNQuaternion {
    static func rotation(from source: SCNVector3, to destination: SCNVector3) -> SCNQuaternion {
        let from = source.normalized
        let to = destination.normalized
        let dot = max(-1, min(1, from.x * to.x + from.y * to.y + from.z * to.z))
        if dot > 0.9999 {
            return SCNQuaternion(0, 0, 0, 1)
        }
        if dot < -0.9999 {
            return SCNQuaternion(1, 0, 0, 0)
        }

        let cross = SCNVector3(
            from.y * to.z - from.z * to.y,
            from.z * to.x - from.x * to.z,
            from.x * to.y - from.y * to.x
        )
        let angle = acos(dot)
        let axis = cross.normalized
        return SCNQuaternion(axis.x, axis.y, axis.z, angle)
    }
}

private extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
