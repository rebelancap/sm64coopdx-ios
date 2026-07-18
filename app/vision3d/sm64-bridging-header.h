// Swift <-> ObjC bridging header for the visionOS target.
//
// Exposes the C/ObjC 3D shell to SM64VisionApp.swift: the host view controller,
// the settings-table factory, the enter/exit entry points, and the immersive
// render loop the CompositorLayer closure hands its layerRenderer to.
//
// Wired via XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER (overlay 0011). Both
// headers are self-gating on TargetConditionals, so nothing here exists off
// visionOS — and nothing else in the tree includes them.

#import "sm64_vision_3d.h"
#import "sm64_vision_host.h"
