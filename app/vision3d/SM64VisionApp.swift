// SM64VisionApp.swift — SwiftUI app entry for the visionOS target.
//
// visionOS requires a SwiftUI `App` to declare an `ImmersiveSpace` (UIKit cannot
// open one), so the app entry is SwiftUI — but it only HOSTS the existing
// UIKit/SDL engine (SM64HostViewController boots it) in a WindowGroup, and
// declares the ImmersiveSpace for stereoscopic 3D. All engine/shell logic stays
// in C/ObjC; this file is scene plumbing only.
//
// NOTE ON THE FILENAME: this file must NOT be called main.swift. Swift treats a
// file with that exact name as top-level code, which collides with @main
// ("'main' attribute cannot be used in a module that contains top-level code").
// Measured, not guessed — it is the first thing that failed in the build spike.

import SwiftUI
import CompositorServices
import AVFAudio

// Shared bridge the ObjC/C side pokes to open/close the 3D immersive space.
final class SM64AppModel: ObservableObject {
    static let shared = SM64AppModel()
    @Published var immersive = false
    @Published var showSettings = false
}

// Called from sm64_vision_host.m to flip the SwiftUI state that actually
// opens/dismisses the space.
@_cdecl("SM64_SetImmersiveMode")
func SM64_SetImmersiveMode(_ on: Bool) {
    DispatchQueue.main.async { SM64AppModel.shared.immersive = on }
}

// Settings "Done" bridge (the UIKit bar button cannot dismiss a SwiftUI sheet).
@_cdecl("SM64_CloseSettingsSheet")
func SM64_CloseSettingsSheet() {
    DispatchQueue.main.async { SM64AppModel.shared.showSettings = false }
}

@_cdecl("SM64_OpenSettingsSheet")
func SM64_OpenSettingsSheet() {
    DispatchQueue.main.async { SM64AppModel.shared.showSettings = true }
}

// In 3D, anchor the app's sound stage to the FRONT of the user — at the panel —
// instead of at the (parked-aside) 2D window (guide §2.7). Restored on exit.
//
// Comfort batch 2 item 4: the user reported the audio "sounds like it's to the
// right of me" — the sound stage following the parked window instead of the
// panel. The fix is anchoringStrategy: .front (below), which pins the stage to
// the user's front regardless of where the window sits. This ALSO logs the active
// AVAudioSession category so the applied state can be confirmed live over the
// port-8791 bridge (`logtail`) while the user plays — because whether it "worked"
// is an ears-on-device judgement, and the log is how we cross-check that the
// .front call actually fired and did not throw.
private func sm64SetAudioFrontStage(_ on: Bool) {
    let session = AVAudioSession.sharedInstance()
    do {
        if on {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .medium, anchoringStrategy: .front))
        } else {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic))
        }
        NSLog("[sm64vp] Swift: audio spatial experience -> \(on ? "FRONT-anchored (medium stage)" : "automatic") "
            + "[session category=\(session.category.rawValue) active-route=\(session.currentRoute.outputs.first?.portType.rawValue ?? "none")]")
    } catch {
        NSLog("[sm64vp] Swift: setIntendedSpatialExperience(\(on ? "front" : "auto")) FAILED: \(error)")
    }
}

// Hosts the UIKit engine bootstrap inside SwiftUI.
struct SM64WindowView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SM64HostViewController {
        return SM64HostViewController()
    }
    func updateUIViewController(_ vc: SM64HostViewController, context: Context) {}
}

// Hosts the UIKit settings table in the SwiftUI sheet: a UIKit modal presented
// directly works in 2D but silently fails over an open ImmersiveSpace.
struct SM64SettingsSheet: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        return SM64_MakeSettingsNav()
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}

// CompositorServices layer configuration for the immersive (3D) render path.
// Capabilities are QUERIED so we never request an unsupported combination —
// that makes openImmersiveSpace fail with a generic .error that names nothing.
struct SM64CompositorConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        let layouts = capabilities.supportedLayouts(options: [])
        configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
        configuration.isFoveationEnabled = false
        configuration.colorFormat = capabilities.supportedColorFormats.first ?? .bgra8Unorm_srgb
        configuration.depthFormat = capabilities.supportedDepthFormats.first ?? .depth32Float
        NSLog("[sm64vp] Swift: compositor configured (layered=\(layouts.contains(.layered)))")
    }
}

// The window's root View — owns the immersive open/close environment actions
// (only valid inside a View, NOT the App struct, where they silently no-op) and
// the ornament controls.
struct SM64RootView: View {
    @ObservedObject private var model = SM64AppModel.shared
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        SM64WindowView()
            .ignoresSafeArea()
            // 3D + settings in a BOTTOM ornament, pushed fully BELOW the window.
            // contentAlignment .top anchors the pill's TOP edge to the window's
            // bottom edge — the default centered ornament straddles the boundary
            // and overlaps game content. .padding(.top) adds the clear gap.
            .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
                HStack(spacing: 16) {
                    Button(model.immersive ? "Exit" : "3D") {
                        sm64_3d_enter(!model.immersive)
                    }
                    Button { model.showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
                .font(.title3) // larger, readable
                .buttonStyle(.borderless)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassBackgroundEffect()
                .opacity(0.85)
                .padding(.top, 14)
            }
            // WIDE sheet: precision room for the live panel sliders. The header
            // (with Done) is SwiftUI-owned — a hosted UIKit nav-bar Done does not
            // survive presentation from the small parked window, which would
            // leave the window-close X as the only exit (and that kills the audio
            // session). Width-only frame: forcing a height taller than the sheet
            // surface makes SwiftUI center-clip the content and eat the Done bar.
            .sheet(isPresented: $model.showSettings) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Settings").font(.title3.weight(.semibold))
                        Spacer()
                        Button("Done") { model.showSettings = false }
                            .font(.title3)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    Divider()
                    SM64SettingsSheet()
                }
                .frame(minWidth: 900)
            }
            .onChange(of: model.immersive) { _, on in
                NSLog("[sm64vp] Swift: immersive onChange -> \(on)")
                Task {
                    if on {
                        let r = await openImmersiveSpace(id: "SM64-3D")
                        NSLog("[sm64vp] Swift: openImmersiveSpace -> \(String(describing: r))")
                        if case .error = r {
                            // Roll everything back — the engine must not stay in
                            // offscreen mode with the window still visible, or it
                            // renders to textures nobody is showing.
                            sm64_3d_enter(false)
                        } else {
                            sm64SetAudioFrontStage(true)
                            // The space has finished opening — NOW park the 2D
                            // window down to a small card (guide §2.7). Doing it
                            // here rather than in sm64_3d_enter avoids a window
                            // resize animation colliding with the entry animation
                            // (vkQuake VKQHostViewController.m:63).
                            sm64_3d_park_window()
                        }
                    } else {
                        await dismissImmersiveSpace()
                        NSLog("[sm64vp] Swift: dismissed immersive")
                        sm64SetAudioFrontStage(false)
                        sm64_3d_exit_finalize()
                    }
                }
            }
    }
}

@main
struct SM64VisionApp: App {
    var body: some Scene {
        WindowGroup {
            SM64RootView()
        }
        ImmersiveSpace(id: "SM64-3D") {
            CompositorLayer(configuration: SM64CompositorConfiguration()) { layerRenderer in
                // This closure runs on the MAIN thread; the frame loop must NOT
                // (it would block the engine's frame pump -> whole-app freeze).
                NSLog("[sm64vp] Swift: CompositorLayer ready — spawning render thread")
                let renderThread = Thread {
                    sm64_3d_immersive_run(Unmanaged.passUnretained(layerRenderer).toOpaque())
                }
                renderThread.name = "SM64-Immersive"
                renderThread.stackSize = 2 << 20
                renderThread.start()
            }
        }
        // MIXED ONLY. Merely ALLOWING .progressive here changes the drawable
        // contract (portal rendering) and cp_drawable_encode_present aborts
        // __BUG_IN_CLIENT__. Crown-dimming would need real portal support; the
        // "Surroundings Dimming" slider is our in-app replacement.
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
