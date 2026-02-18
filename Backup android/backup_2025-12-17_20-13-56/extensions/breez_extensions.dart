import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart';

/// Extension to add copyWith method to Breez SDK Config
extension ConfigCopyWith on Config {
  Config copyWith({
    String? apiKey,
    Network? network,
    int? syncIntervalSecs,
    Fee? maxDepositClaimFee,
    String? lnurlDomain,
    bool? preferSparkOverLightning,
    List<ExternalInputParser>? externalInputParsers,
    bool? useDefaultExternalInputParsers,
    String? realTimeSyncServerUrl,
  }) {
    return Config(
      apiKey: apiKey ?? this.apiKey,
      network: network ?? this.network,
      syncIntervalSecs: syncIntervalSecs ?? this.syncIntervalSecs,
      maxDepositClaimFee: maxDepositClaimFee ?? this.maxDepositClaimFee,
      lnurlDomain: lnurlDomain ?? this.lnurlDomain,
      preferSparkOverLightning: preferSparkOverLightning ?? this.preferSparkOverLightning,
      externalInputParsers: externalInputParsers ?? this.externalInputParsers,
      useDefaultExternalInputParsers: useDefaultExternalInputParsers ?? this.useDefaultExternalInputParsers,
      realTimeSyncServerUrl: realTimeSyncServerUrl ?? this.realTimeSyncServerUrl,
    );
  }
}

/// Extension for WaitForPaymentRequest to support different identifiers
extension WaitForPaymentRequestExt on WaitForPaymentRequest {
  static WaitForPaymentRequest byPaymentHash(String paymentHash, int timeoutSecs) {
    return WaitForPaymentRequest(
      identifier: WaitForPaymentIdentifier.paymentRequest(paymentHash),
    );
  }

  static WaitForPaymentRequest byPaymentId(String paymentId) {
    return WaitForPaymentRequest(
      identifier: WaitForPaymentIdentifier.paymentId(paymentId),
    );
  }
}
