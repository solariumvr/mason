import 'dart:mason' as mason;
import 'dart:materials' as materials;
import 'dart:async';
import 'asset_bundle.dart';

/// Returns a list of [mason.Renderable]'s from a glTF scene.
Future<List<mason.Renderable>> renderStaticScene(Scene scene) async {
  List<mason.Renderable> renderables = [];

  // All materials must be created using a [MaterialBuilder]
  var materialBuilder = new materials.MaterialBuilder();

  // Constants such as double's, Vector2, Vector3, Vector4
  // will be compiled into the shader and can not be changed at a later time.
  materialBuilder.baseColor = new materials.Vector4Param(
      "baseColor", new mason.Vector4(0.2, 0.2, 0.2, 1.0));

  //Material Parameters can be changed
  materialBuilder.metallic = new materials.ScalarParam("metallic", 0.0);
  //Make sure not to use 0.0 for roughness, use low value above 0.0;
  materialBuilder.roughness = new materials.ScalarParam("roughness", 1.0);

  // the compile process is asynchronous
  var material = await materialBuilder.compile();

  _renderNodes(
      scene.children, new mason.Matrix4.identity(), renderables, material);

  return renderables;
}

_renderNodes(List<Node> nodes, mason.Matrix4 transform,
    List<mason.Renderable> renderables, materials.Material material) {
  for (var node in nodes) {
    var t = node.transform.matrix * transform;
    if (node.mesh != null) {
      for (var primitive in node.mesh.primitives) {
        var mi = material.createInstance();
        if (primitive.material != null) {
          mi.setParam("baseColor",
              primitive.material.metallicRoughness.baseColorFactor);
          mi.setParam(
              "metallic", primitive.material.metallicRoughness.metallicFactor);
        }
        renderables.add(new mason.Renderable(mi, primitive.mesh, t));
      }
    }
    _renderNodes(node.children, t, renderables, material);
  }
}
