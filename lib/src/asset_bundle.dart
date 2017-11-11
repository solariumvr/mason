import 'dart:mason' as mason;
import 'dart:solarium_io' as io;
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:async/async.dart';
import 'package:path/path.dart' as path;

enum AlphaMode {
  BLEND,
  OPAQUE,
  MASK,
}

class AssetBundle {
  /// Imports a .gltf or .glb file
  static Future<AssetBundle> import(String url) async {
    var client = new io.HttpClient();

    io.HttpResponse response = await client.get(url);
    var dir = path.dirname(response.finalUrl.toString());

    var assetBundle = new AssetBundle._();

    if (response.headers.contentType.mimeType != "model/gltf+json") {
      throw new Exception("Invalid file type.");
    }

    var allBytes = new List<int>();

    await response.body.readBytes().listen((data) {
      allBytes.addAll(data);
    }).asFuture();

    String s = new String.fromCharCodes(allBytes);
    var parsed = JSON.decode(s);
    var defaultSceneIndex = parsed["scene"];
    var scenes = parsed["scenes"];

    /// Process buffers
    for (var buffer in parsed['buffers']) {
      var uri = buffer['uri'];
      if (uri == null) {
        /// There buffer is embedded in file(glb)
      } else if (uri is String && uri.startsWith("data:")) {
        //BASE64 encoded data.
        var data = BASE64URL.decode(uri);
      } else if (uri is String) {
        uri = path.join(dir, uri);
        var futureBytes = client.get(uri).then((response) {
          return collectBytes(response.body.readBytes()).then((data) {
            return data;
          });
        });
        var byteLength = buffer['byteLength'];
        var name = buffer['name'];
        //Need to get the buffer.
        assetBundle.buffers.add(new BufferData(
            uri: uri, name: name, byteLength: byteLength, data: futureBytes));
      }
    }

    for (var materialData in parsed["materials"]) {
      var material = new Material();
      switch (materialData["alphaMode"]) {
        case "BLEND":
          material.alphaMode = AlphaMode.BLEND;
          break;
        case "OPAQUE":
          material.alphaMode = AlphaMode.OPAQUE;
          break;
        case "MASK":
          material.alphaMode = AlphaMode.MASK;
          break;
        default:
          material.alphaMode = AlphaMode.OPAQUE;
          break;
      }

      if (materialData["emissiveFactor"] != null) {
        material.emissiveFactor = new mason.Vector3(
            materialData["emissiveFactor"][0],
            materialData["emissiveFactor"][1],
            materialData["emissiveFactor"][2]);
      } else {
        material.emissiveFactor = new mason.Vector3.zero();
      }
      var pbrData = materialData["pbrMetallicRoughness"];
      if (pbrData != null) {
        var mr = new MetallicRoughness();
        if (pbrData["baseColorFactor"] != null) {
          mr.baseColorFactor =
              new mason.Vector4.array(pbrData["baseColorFactor"]);
        }
        if (pbrData["metallicFactor"] != null) {
          mr.metallicFactor = pbrData["metallicFactor"];
        }

        material.metallicRoughness = mr;
      }

      assetBundle.materials.add(material);
    }

    /// Process meshes
    for (var meshData in parsed['meshes']) {
      var mesh = new Mesh();
      for (var primitiveData in meshData["primitives"]) {
        var primitive = new Primitive();
        if (primitiveData["material"] != null) {
          primitive.material = assetBundle.materials[primitiveData["material"]];
        }
        var indexAccessor = parsed['accessors'][primitiveData["indices"]];
        var indexComponent = _getComponentType(indexAccessor["componentType"]);

        var attributes = [];
        int vertexCount = 0;
        var vertexBytes = 0;

        var accessors = [];

        primitiveData['attributes'].forEach((attribute, accessorIndex) {
          var accessor = parsed['accessors'][accessorIndex];
          var bufferView = parsed['bufferViews'][accessor['bufferView']];
          accessor["attribute"] = attribute;
          accessor.addAll(bufferView);
          accessors.add(accessor);
        });

        accessors.sort((a, b) {
          if (a["byteOffset"] < b["byteOffset"]) {
            return -1;
          } else {
            return 1;
          }
        });

        accessors.forEach((accessor) {
          vertexCount = accessor["count"];
          String type = accessor["type"];

          mason.MeshAttribute attributeEnum;
          mason.AccessorType accessorType;
          switch (accessor["attribute"]) {
            case "POSITION":
              attributeEnum = mason.MeshAttribute.POSITION;
              break;
            case "NORMAL":
              attributeEnum = mason.MeshAttribute.NORMAL;
              break;
            case "COLOR_0":
              attributeEnum = mason.MeshAttribute.COLOR_0;
              break;
            case "TEXCOORD_0":
              attributeEnum = mason.MeshAttribute.TEXCOORD_0;
              break;
            case "TANGENT":
              attributeEnum = mason.MeshAttribute.TANGENT;
              break;
          }

          switch (accessor["type"]) {
            case "VEC2":
              accessorType = mason.AccessorType.VEC2;
              break;
            case "VEC3":
              accessorType = mason.AccessorType.VEC3;
              break;
            case "VEC4":
              accessorType = mason.AccessorType.VEC4;
              break;
          }

          mason.ComponentType component =
              _getComponentType(accessor["componentType"]);

          var attributeDesc = new mason.AttributeDescription(
              attributeEnum, accessorType, component);

          attributes.add(attributeDesc);
        });

        var bufferView = parsed["bufferViews"][indexAccessor["bufferView"]];
        var indexBuffer = await assetBundle.buffers[bufferView['buffer']].data;
        var indexData = new Uint8List.view(indexBuffer.buffer,
            bufferView['byteOffset'], bufferView['byteLength']);

        var vertexBuffer =
            await assetBundle.buffers[accessors.first['buffer']].data;
        var offset = accessors.first["byteOffset"];
        var length = accessors.last["byteOffset"] +
            accessors.last["byteLength"] -
            offset;

        primitive.mesh = await mason.Mesh.create(
            vertexCount, indexAccessor["count"], attributes,
            indexComponentType: indexComponent);
        primitive.mesh.setIndices(indexData);
        primitive.mesh.setVertices(
            new Uint8List.view(vertexBuffer.buffer, offset, length));

        assetBundle.meshInstances.add(primitive.mesh);

        mesh.primitives.add(primitive);
      }

      assetBundle.meshes.add(mesh);
    }

    for (var sceneData in parsed["scenes"]) {
      var nodeIndexes = sceneData["nodes"];
      var scene = new Scene();
      scene.name = sceneData["name"];
      if (nodeIndexes != null) {
        for (var nodeIndex in nodeIndexes) {
          scene.children.add(assetBundle._processNode(
              parsed["nodes"][nodeIndex], parsed["nodes"]));
        }
      }
      assetBundle.scenes.add(scene);
    }

    return new Future.value(assetBundle);
  }

  Node _processNode(nodeData, List<Map> nodesJson) {
    var node = new Node();
    node.name = nodeData["name"];
    var rotation = nodeData["rotation"];
    if (rotation == null) {
      rotation = [0.0, 0.0, 0.0, 1.0];
    }
    var scale = nodeData["scale"];
    if (scale == null) {
      scale = [1.0, 1.0, 1.0];
    }
    var translation = nodeData["translation"];
    if (translation == null) {
      translation = [0.0, 0.0, 0.0];
    }
    var transform = new mason.Transform(
        position:
            new mason.Vector3(translation[0], translation[1], translation[2]),
        rotation: new mason.Quaternion(
            rotation[0], rotation[1], rotation[2], rotation[3]),
        scale: new mason.Vector3(scale[0], scale[1], scale[2]));
    node.transform = transform;
    var childrenIndexes = nodeData["children"];
    if (childrenIndexes != null && !childrenIndexes.isEmpty) {
      for (var c in childrenIndexes) {
        node.children.add(_processNode(nodesJson[c], nodesJson));
      }
    }
    if (nodeData["mesh"] != null) {
      node.mesh = meshes[nodeData["mesh"]];
    }
    return node;
  }

  Scene defaultScene;

  List<Scene> scenes = new List<Scene>();

  List<BufferData> buffers = new List<BufferData>();

  List<Node> nodes = new List<Node>();

  List<Material> materials = new List<Material>();

  List<Mesh> meshes = new List<Mesh>();
  List<mason.Mesh> meshInstances = new List<mason.Mesh>();

  AssetBundle._() {}
}

mason.ComponentType _getComponentType(int componentInt) {
  mason.ComponentType component;
  switch (componentInt) {
    case 5126:
      component = mason.ComponentType.FLOAT;
      break;
    case 5121:
      component = mason.ComponentType.UNSIGNED_BYTE;
      break;
    case 5123:
      component = mason.ComponentType.UNSIGNED_SHORT;
      break;
  }
  return component;
}

class BufferData {
  String uri;
  String name;
  int byteLength;
  Future<Uint8List> data;

  BufferData({this.uri, this.name, this.byteLength, this.data}) {}
}

class Scene {
  String name;
  List<Node> children = new List<Node>();
}

class Node {
  String name;
  mason.Transform transform;
  List<Node> children = new List<Node>();
  Mesh mesh;

  String toString() {
    return "Node: ${name}";
  }
}

class Primitive {
  mason.Mesh mesh;
  Material material;
}

class Material {
  String name;
  AlphaMode alphaMode;
  mason.Vector3 emissiveFactor;
  MetallicRoughness metallicRoughness;
}

class MetallicRoughness {
  mason.Vector4 baseColorFactor = new mason.Vector4.zero();
  double metallicFactor = 0.0;
}

class Mesh {
  String name;
  List<Primitive> primitives = [];
}
