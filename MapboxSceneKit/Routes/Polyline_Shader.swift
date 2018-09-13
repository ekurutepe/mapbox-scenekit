//
//  LineNode.swift
//  line-rendering
//
//  Created by Jim Martin on 8/2/18.
//  Copyright © 2018 MapBox. All rights reserved.
//

import Foundation
import SceneKit
import Metal

/// Uses a Metal Shader to give that geometry a set radius in screen-space. Not compatible with iOS simulator builds.
///
/// - Parameters:
///   - positions: The list of SCNVector3 positions. The line is drawn through each position consectutively from 0...n
///   - startRadius: The width of the initial point of the line. Linearly interpolated from start to end positions.
///   - endRadius: The width of the final point of the line. Linearly interpolated from start to end positions.
///   - startColor: The color of the initial point of the line. Linearly interpolated through RGB color space from start to end.
///   - endColor: The color of the final point of the line. Linearly interpolated through RGB color space from start to end.
///   - handleGeometryOverlap: !Experimental! Flag indicating whether the line radius should be used to handle overlap/z-fighting per-pixel. Greatly improves visual quality of lines intersecting with other geometry, but at some cost to performance. May create graphical artifacts on some devices.
@available(iOS 10.0, *)
internal class Polyline_Shader: PolylineRenderer {
    
    private weak var polyline: PolylineNode?
    private var sampleCount: Int = 0
    
    private let defaultColor: UIColor = .magenta
    private let defaultRadius: CGFloat = 5
    
    //derived from position, radius, and color settings
    private var verts: [SCNVector3]! //components -> quads
    private var normals: [SCNVector3]! //Appears as 'neighbors' in the vertex input. Used to pass the line segment(direction and magnitude) to each vertex.
    private var indices: [Int32]!
    private var uvs: [CGPoint]! //uv per vert, indicating the corner of the quad
    private var colors: [SCNVector4]! //vertex colors
    private var lineParams: [CGPoint]! //line radius captured in y value
    

    public func render(_ polyline: PolylineNode, withSampleCount sampleCount: Int) {
        
        self.polyline = polyline
        self.sampleCount = sampleCount
        guard sampleCount > 0 else { return }
        
        //assign geometry
        polyline.geometry = generateGeometry()
        
        //assign materials
        polyline.geometry?.firstMaterial = generateMaterial()
    }
    
    private func progressAtSample(_ sample: Int) -> CGFloat {
        return (CGFloat(sample) / CGFloat(sampleCount))
    }
    
    private func generateMaterial() -> SCNMaterial{
        
        //assign materials using the scenekit metal library
        let lineMaterial = SCNMaterial()
        let program = SCNProgram(withLibraryForClass: type(of: self))
        program.fragmentFunctionName = "lineFrag"
        program.vertexFunctionName = "lineVert"
        program.isOpaque = false
        lineMaterial.program = program
        lineMaterial.isDoubleSided = true
        lineMaterial.blendMode = .alpha
        return lineMaterial
    }
    
    private func generateGeometry() -> SCNGeometry{
        
        //reset geometry
        verts = []
        uvs = []
        colors = []
        lineParams = []
        normals = []
        indices = []
        
        if let polyline = self.polyline {
            
            for index in 1..<sampleCount
            {
                let lastPosition = polyline.getPositon(atProgress: progressAtSample(index - 1))
                let position = polyline.getPositon(atProgress: progressAtSample(index))
                addLine(from: lastPosition, to: position, withIndex: index)
            }
            
            for index in (0..<sampleCount).reversed()
            {
                let position = polyline.getPositon(atProgress: progressAtSample(index))
                addCap(atPosition: position, withIndex: index)
            }
            
        }
        
        //create geometry from sources
        let vertSource = SCNGeometrySource(vertices: verts)
        let normalSource = SCNGeometrySource(normals: normals)
        let uvSource = SCNGeometrySource(textureCoordinates: uvs)
        let colorSource = SCNGeometrySource(colors: colors)
        let lineDimensionSource = SCNGeometrySource(textureCoordinates: lineParams)
        let elements = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [vertSource, normalSource, uvSource, lineDimensionSource, colorSource], elements: [elements])
    }
    
    private func addCap(atPosition position: SCNVector3, withIndex index: Int){
        
        let vertIndex = verts.count
        
        //add vert
        verts.append(contentsOf: [position, position, position, position])
        
        //neighboring point captured in normals
        normals.append(contentsOf: [position, position, position, position])
        
        //set UVs
        uvs.append(contentsOf: billboardUVs())
        
        //set Color
        let color = polyline?.getColor(atProgress: progressAtSample(index)).asSCNVector() ?? defaultColor.asSCNVector()
        colors.append(contentsOf: [color, color, color, color])
        
        //set line radius and geometry overlap settings
        let radius = polyline?.getRadius(atProgress: progressAtSample(index)) ?? defaultRadius
        let lineParam = CGPoint(x: 0, y: radius)
        lineParams.append(contentsOf: [lineParam, lineParam, lineParam, lineParam])
        
        //add indices
        indices.append(contentsOf: getQuadIndices(fromIndex: vertIndex))

    }
    
    private func addLine(from: SCNVector3, to: SCNVector3, withIndex index: Int){
        
        let vertIndex = verts.count
        
        //add vert
        verts.append(contentsOf: [from, from, to, to])
        
        //neighboring point captured in normals
        normals.append(contentsOf: [to, to, from, from])
        
        //set UVs
        uvs.append(contentsOf: billboardUVs())
        
        //set Color
        let fromColor = polyline?.getColor(atProgress: progressAtSample(index - 1)).asSCNVector() ?? defaultColor.asSCNVector()
        let toColor = polyline?.getColor(atProgress: progressAtSample(index)).asSCNVector() ?? defaultColor.asSCNVector()
        colors.append(contentsOf: [fromColor, fromColor, toColor, toColor])
        
        //set line radius and geometry overlap settings
        let fromRadius = polyline?.getRadius(atProgress: progressAtSample(index - 1)) ?? defaultRadius
        let toRadius = polyline?.getRadius(atProgress: progressAtSample(index)) ?? defaultRadius
        let fromParam = CGPoint(x: 0, y: fromRadius)
        let toParam = CGPoint(x: 0, y: toRadius)
        lineParams.append(contentsOf: [fromParam, fromParam, toParam, toParam])
        
        //add indices
        indices.append(contentsOf: getQuadIndices(fromIndex: vertIndex))
    }
    
    //return indices for two joined triangles, creating a quad
    private func getQuadIndices(fromIndex vertIndex: Int) -> [Int32]{
        return [Int32(vertIndex),
                Int32(vertIndex + 1),
                Int32(vertIndex + 2),
                Int32(vertIndex + 3),
                Int32(vertIndex + 2),
                Int32(vertIndex + 1)]
    }
    
    private func billboardUVs() -> [CGPoint]{
        
        let uvSet1 = CGPoint(x: 1, y: 0)
        let uvSet2 = CGPoint(x: 0, y: 0)
        let uvSet3 = CGPoint(x: 1, y: 1)
        let uvSet4 = CGPoint(x: 0, y: 1)
        
        return [uvSet1, uvSet2, uvSet3, uvSet4]
    }
}

//MARK: - SCNGEOMETRYSOURCE EXTENSIONS
extension SCNGeometrySource {
    
    convenience init( colors: [SCNVector4]){
        
        let colorData = NSData(bytes: colors, length: MemoryLayout<SCNVector4>.stride * colors.count) as Data
        self.init(data: colorData, semantic: SCNGeometrySource.Semantic.color, vectorCount: colors.count, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.stride, dataOffset: 0, dataStride: MemoryLayout<SCNVector4>.stride)
        
    }
}


//MARK: - LERP EXTENSIONS
fileprivate extension UIColor {
    
    func asSCNVector() -> SCNVector4 {
        var r : CGFloat = 0
        var g : CGFloat = 0
        var b : CGFloat = 0
        var a : CGFloat = 0
        self.getRed(&r, green: &g, blue: &b, alpha: &a)
        
        let color = SCNVector4(r, g, b, a)
        return color
    }
}
