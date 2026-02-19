import Cocoa
import FlutterMacOS
import CryptoTokenKit

public class FlutterSmartCardPlugin: NSObject, FlutterPlugin {
    private var smartCard: TKSmartCard?
    private var session: TKSmartCardSlot?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "flutter_smart_card", binaryMessenger: registrar.messenger)
        let instance = FlutterSmartCardPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "listReaders":
            listReaders(result: result)
        case "connect":
            connect(call: call, result: result)
        case "transmit":
            transmit(call: call, result: result)
        case "disconnect":
            disconnect(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func listReaders(result: @escaping FlutterResult) {
        if let manager = TKSmartCardSlotManager.default {
            result(manager.slotNames)
        } else {
            result([])
        }
    }

    private func connect(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let readerName = args["reader"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "Reader name is required", details: nil))
            return
        }

        guard let manager = TKSmartCardSlotManager.default else {
            result(FlutterError(code: "UNAVAILABLE", message: "Smart card manager unavailable", details: nil))
            return
        }

        manager.getSlot(withName: readerName) { slot in
            guard let slot = slot else {
                result(FlutterError(code: "DEVICE_NOT_FOUND", message: "Reader not found", details: nil))
                return
            }

            if let card = slot.makeSmartCard() {
                card.beginSession { success, error in
                    if success {
                        self.smartCard = card
                        self.session = slot
                        result(true)
                    } else {
                        result(FlutterError(code: "CONNECTION_FAILED", message: error?.localizedDescription, details: nil))
                    }
                }
            } else {
                result(FlutterError(code: "NO_CARD", message: "No card inserted", details: nil))
            }
        }
    }

    private func transmit(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let apduData = args["apdu"] as? FlutterStandardTypedData else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "APDU data is required", details: nil))
            return
        }

        guard let card = self.smartCard else {
            result(FlutterError(code: "NOT_CONNECTED", message: "Not connected to a card", details: nil))
            return
        }

        let data = apduData.data
        card.transmit(data) { response, error in
            if let response = response {
                result(response)
            } else {
                result(FlutterError(code: "TRANSMIT_FAILED", message: error?.localizedDescription, details: nil))
            }
        }
    }

    private func disconnect(result: @escaping FlutterResult) {
        if let card = self.smartCard {
            card.endSession()
            self.smartCard = nil
            self.session = nil
        }
        result(nil)
    }
}
