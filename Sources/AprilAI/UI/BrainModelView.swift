import AppKit
import Foundation
import SceneKit
import SwiftUI

struct BrainModelView: NSViewRepresentable {
    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = BrainSceneFactory.makeScene()
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        if view.scene == nil {
            view.scene = BrainSceneFactory.makeScene()
        }
        view.isPlaying = true
    }
}

private enum BrainSceneFactory {
    static func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear

        let orbit = SCNNode()
        let model = modelNode() ?? fallbackNode()
        orbit.addChildNode(model)
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
        key.intensity = 950
        key.temperature = 6200
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(1.8, 2.2, 2.4)
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .ambient
        fill.intensity = 320
        fill.color = NSColor(calibratedRed: 0.45, green: 0.65, blue: 1.0, alpha: 1.0)
        let fillNode = SCNNode()
        fillNode.light = fill
        scene.rootNode.addChildNode(fillNode)

        orbit.runAction(.repeatForever(.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 22)))
        model.runAction(.repeatForever(.sequence([
            .moveBy(x: 0, y: 0.04, z: 0, duration: 2.6),
            .moveBy(x: 0, y: -0.04, z: 0, duration: 2.6)
        ])))

        return scene
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

private extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
