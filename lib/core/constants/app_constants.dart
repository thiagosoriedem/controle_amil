/// Application-wide constants
class AppConstants {
  // Storage keys
  static const String keyHistoricoConsultas = 'historico_consultas';
  static const String keyHistoricoPlantoes = 'historico_plantoes';
  static const String keyConvenios = 'convenios';
  static const String keyMetaDiaria = 'meta_diaria';
  static const String keyMetaMensal = 'meta_mensal';
  static const String keyTaxaDesconto = 'taxa_desconto';
  static const String keyValorBonusPlantao = 'valor_bonus_plantao';
  static const String keyValorAdicionalPlantao = 'valor_adicional_plantao';
  static const String keySyncPort = 'sync_port';
  static const String keyTemaSelecionado = 'tema_selecionado';
  static const String keySyncAutomaticoAtivo = 'sync_automatico_ativo';
  static const String keyParceiroSyncIp = 'parceiro_sync_ip';
  static const String keySyncToken = 'sync_token';

  // Default values
  static const double defaultTaxaDesconto = 0.158;
  static const double defaultValorBonusPlantao = 100.0;
  static const double defaultValorAdicionalPlantao = 7.0;
  static const int defaultSyncPort = 8080;
  static const String defaultTema = 'rosa';

  // Network
  static const String serviceType = '_controleamil._tcp';
  static const int discoveryTimeoutSeconds = 10;
  static const int httpTimeoutSeconds = 5;
  static const int syncAuthExpiryMinutes = 5;

  // Version
  static const String appName = 'Telemedicina Amil';

  // Revenue chart
  static const int defaultRevenueChartDays = 7;
}