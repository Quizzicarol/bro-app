import Flutter
import UIKit

// Build-time stub applied by codemagic.yaml.
//
// Bro uses mnemonic (BIP-39) seeds, NOT passkeys. The upstream
// breez_sdk_spark_flutter 0.19.2 passkey implementation
// (BreezSdkSparkPasskeyPlugin + PasskeyAssertionCore + PasskeyPRFHelperObjC)
// only compiles under Swift Package Manager. Under CocoaPods (which is what
// Flutter uses for this plugin) it fails to build: the `PasskeyPRFHelperObjC`
// Clang module does not exist and there are optional-unwrap errors.
//
// This stub preserves plugin registration (pubspec iOS pluginClass is
// `BreezSdkSparkPasskeyPlugin`) so GeneratedPluginRegistrant keeps compiling.
// The "breez_sdk_spark_passkey" MethodChannel is never invoked by the app.
@available(iOS 18.0, *)
public class BreezSdkSparkPasskeyPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "breez_sdk_spark_passkey",
            binaryMessenger: registrar.messenger()
        )
        let instance = BreezSdkSparkPasskeyPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "isSupported" {
            result(false)
        } else {
            result(FlutterError(
                code: "ERR_PASSKEY_DISABLED",
                message: "Passkey support is disabled in this build",
                details: nil
            ))
        }
    }
}
