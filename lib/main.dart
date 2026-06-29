import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:shelf/shelf.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:nsd/nsd.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_router;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'models/convenio.dart';
import 'models/consulta_registro.dart';
import 'models/plantao_registro.dart';
import 'models/tema_customizado.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Telemedicina Amil - Lógica Completa',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        primaryColor: const Color(0xFF2563EB),
      ),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  // --- Banco de Dados Local Simulado (Estados Dinâmicos) ---
  final List<ConsultaRegistro> _historicoConsultas = [];
  List<Convenio> _convenios = [];

  List<Convenio> _getConveniosPadrao() {
    return [
      Convenio(
        id: 'adulto',
        nome: 'Fila Adulto',
        valor: 15.0,
        cor: Colors.purple,
      ),
      Convenio(id: 'ped', nome: 'Fila Ped', valor: 18.0, cor: Colors.blue),
      Convenio(id: 'amilum', nome: 'Amil Um', valor: 20.0, cor: Colors.green),
    ];
  }

  // --- Estado do Registro de Plantões ---
  final List<PlantaoRegistro> _historicoPlantoes = [];
  bool _chamei5Pacientes = false;
  final TextEditingController _pacientesAdicionaisController =
      TextEditingController();
  final double _valorBasePlantao = 100.0;
  final double _valorAdicionalPlantao = 7.0;

  // Configurações de Metas
  double metaDiaria = 0.0;
  double metaMensal = 0.0;
  final TextEditingController _metaDiariaController = TextEditingController();
  final TextEditingController _metaMensalController = TextEditingController();

  // Configuração da taxa de desconto
  double taxaDesconto = 0.158; // Padrão de 15.8%
  final TextEditingController _taxaDescontoController = TextEditingController();

  // Configurações de Rede
  String? meuIpLocal;
  HttpServer? _server;
  final TextEditingController _ipDestinoController = TextEditingController();
  int _syncPort = 8080;
  final TextEditingController _syncPortController = TextEditingController();

  // Controle de autorização de conexão
  String? _ipSincronizacaoAutorizado;
  DateTime? _autorizacaoExpira;

  // Descoberta de Rede
  final List<Service> _discoveredServices = [];
  bool _isDiscovering = false;
  StreamSubscription<Service>? _discoverySubscription;
  Registration? _registration;

  // Sincronização Automática
  bool _syncAutomaticoAtivo = false;
  String? _parceiroSyncIp;
  bool _solicitacaoEmProgresso = false;

  // Tema customizado
  String _temaSelecionado = 'rosa';

  // Estado para o gráfico de pizza
  int _touchedIndex = -1;

  // Estado para o gráfico de faturamento
  DateTime _revenueChartStartDate = DateTime.now().subtract(
    const Duration(days: 6),
  );
  DateTime _revenueChartEndDate = DateTime.now();

  // NOVO: Estado para a data de análise dos gráficos diários
  DateTime _analiseDataSelecionada = DateTime.now();

  TemaCustomizado get temaAtual => temasPredefinidos[_temaSelecionado]!;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  // Orquestra a inicialização assíncrona para evitar race conditions
  Future<void> _initApp() async {
    // Carrega dados e informações de rede/dispositivo primeiro
    await _carregarDados();
    await _obterIpLocal();
    await _getDeviceName();

    // Só então inicia o servidor, que depende do nome do dispositivo
    _iniciarServidorSincronizacao();
  }

  @override
  void dispose() {
    _discoverySubscription?.cancel();
    if (_registration != null) {
      unregister(_registration!);
    }
    super.dispose();
  }

  String _deviceName = 'Dispositivo';

  Future<void> _exportarRelatorioMensalPDF() async {
    // 1. Filtrar dados do mês atual
    final agora = DateTime.now();
    final consultasDoMes = _historicoConsultas
        .where((c) => c.hora.month == agora.month && c.hora.year == agora.year)
        .toList();

    // Se quiser ordenar da mais antiga para a mais nova no relatório
    consultasDoMes.sort((a, b) => a.hora.compareTo(b.hora));

    final receitaBruta = consultasDoMes.fold(0.0, (s, c) => s + c.valor);
    final descontoImpostos = receitaBruta * taxaDesconto;
    final receitaLiquida = receitaBruta - descontoImpostos;

    // --- DADOS PARA GRÁFICOS ---
    // 1. Faturamento por Fila (Gráfico de Pizza)
    final Map<String, double> faturamentoPorFila = {};
    for (var consulta in consultasDoMes) {
      faturamentoPorFila.update(
        consulta.nomeConvenio,
        (value) => value + consulta.valor,
        ifAbsent: () => consulta.valor,
      );
    }

    // 2. Distribuição Horária (Gráfico de Barras)
    final Map<int, int> consultasPorHora = {};
    for (var consulta in consultasDoMes) {
      consultasPorHora.update(
        consulta.hora.hour,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }
    final horasComAtendimento = consultasPorHora.keys.toList()..sort();
    int maxConsultasNaHora = 0;
    if (consultasPorHora.isNotEmpty) {
      maxConsultasNaHora = consultasPorHora.values.reduce(
        (a, b) => a > b ? a : b,
      );
    }
    if (maxConsultasNaHora == 0) maxConsultasNaHora = 1;

    // --- CORES DO TEMA ---
    final corPrimaria = PdfColor.fromInt(temaAtual.cor1.value);
    final corPrimariaClaro = PdfColor(
      temaAtual.cor1.red / 255.0,
      temaAtual.cor1.green / 255.0,
      temaAtual.cor1.blue / 255.0,
      0.2,
    );
    final corSecundaria = PdfColor.fromInt(temaAtual.cor2.value);
    final corFundoClaro = PdfColor.fromInt(temaAtual.fundoBatida.value);

    // 2. Criar o documento PDF com novo layout
    final pdf = pw.Document();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (pw.Context context) {
          return pw.Container(
            alignment: pw.Alignment.centerLeft,
            margin: const pw.EdgeInsets.only(bottom: 3.0 * PdfPageFormat.mm),
            padding: const pw.EdgeInsets.only(bottom: 3.0 * PdfPageFormat.mm),
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                bottom: pw.BorderSide(width: 0.5, color: PdfColors.grey),
              ),
            ),
            child: pw.Text(
              'Relatório de Faturamento - Telemedicina Amil',
              style: pw.Theme.of(
                context,
              ).defaultTextStyle.copyWith(color: PdfColors.grey),
            ),
          );
        },
        footer: (pw.Context context) {
          return pw.Container(
            alignment: pw.Alignment.centerRight,
            margin: const pw.EdgeInsets.only(top: 1.0 * PdfPageFormat.cm),
            child: pw.Text(
              'Página ${context.pageNumber} de ${context.pagesCount}',
              style: pw.Theme.of(
                context,
              ).defaultTextStyle.copyWith(color: PdfColors.grey),
            ),
          );
        },
        build: (pw.Context context) {
          return [
            // Título Principal
            pw.Header(
              level: 0,
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Relatório Mensal',
                    style: pw.TextStyle(
                      fontSize: 24,
                      fontWeight: pw.FontWeight.bold,
                      color: corPrimaria,
                    ),
                  ),
                  pw.Text(
                    '${agora.month.toString().padLeft(2, "0")}/${agora.year}',
                    style: pw.TextStyle(fontSize: 18, color: corSecundaria),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 1.0 * PdfPageFormat.cm),

            // Resumo Financeiro
            pw.Container(
              padding: const pw.EdgeInsets.all(16),
              decoration: pw.BoxDecoration(
                color: corFundoClaro,
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
                border: pw.Border.all(color: corPrimaria, width: 1.5),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'Resumo Financeiro do Mês',
                    style: pw.TextStyle(
                      fontSize: 18,
                      fontWeight: pw.FontWeight.bold,
                      color: corSecundaria,
                    ),
                  ),
                  pw.Divider(color: corPrimaria, height: 20),
                  _buildResumoRowPDF(
                    'Total de Atendimentos:',
                    '${consultasDoMes.length}',
                  ),
                  _buildResumoRowPDF(
                    'Receita Bruta:',
                    'R\$ ${receitaBruta.toStringAsFixed(2)}',
                  ),
                  _buildResumoRowPDF(
                    'Impostos (${(taxaDesconto * 100).toStringAsFixed(1)}%):',
                    '- R\$ ${descontoImpostos.toStringAsFixed(2)}',
                    valorColor: PdfColors.red,
                  ),
                  pw.SizedBox(height: 8),
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: pw.BoxDecoration(
                      color: corPrimariaClaro,
                      borderRadius: const pw.BorderRadius.all(
                        pw.Radius.circular(4),
                      ),
                    ),
                    child: _buildResumoRowPDF(
                      'Receita Líquida Estimada:',
                      'R\$ ${receitaLiquida.toStringAsFixed(2)}',
                      labelStyle: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold,
                        color: corFundoClaro,
                      ),
                      valorStyle: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold,
                        color: corFundoClaro,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 1.0 * PdfPageFormat.cm),

            // Seção de Gráficos
            pw.Text(
              'Análise Gráfica do Mês',
              style: pw.TextStyle(
                fontSize: 20,
                fontWeight: pw.FontWeight.bold,
                color: corPrimaria,
              ),
            ),
            pw.SizedBox(height: 0.5 * PdfPageFormat.cm),
            // The side-by-side layout with `pw.Row` was replaced by a `pw.Column`
            // to prevent the `PdfTooBigPageException`. A `pw.Row` is not pageable,
            // so if its content (e.g., a long list of convenios in the graph legend)
            // becomes taller than a page, it causes an error. This new layout
            // places the graphs one below the other, ensuring they can break
            // across pages correctly.

            // Gráfico de Pizza (Legenda)
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey300),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'Faturamento por Fila',
                    style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      color: corSecundaria,
                    ),
                  ),
                  pw.SizedBox(height: 10),
                  if (receitaBruta > 0) ...[
                    pw.SizedBox(
                      height: 170,
                      child: pw.Chart(
                        grid: pw.PieGrid(),
                        datasets: [
                          // Para esta versão da biblioteca 'pdf', cada PieDataSet representa uma fatia do gráfico.
                          // Iteramos sobre os convênios e criamos uma fatia para cada um que teve faturamento.
                          for (final convenio in _convenios)
                            if ((faturamentoPorFila[convenio.nome] ?? 0.0) > 0)
                              pw.PieDataSet(
                                value: faturamentoPorFila[convenio.nome]!,
                                color: PdfColor.fromInt(convenio.cor.value),
                                legend:
                                    '${(faturamentoPorFila[convenio.nome]! / receitaBruta * 100).toStringAsFixed(0)}%',
                                legendStyle: pw.TextStyle(
                                  fontSize: 10,
                                  color: PdfColors.white,
                                  fontWeight: pw.FontWeight.bold,
                                ),
                              ),
                        ],
                      ),
                    ),
                    pw.SizedBox(height: 20),
                    pw.Text(
                      'Legenda:',
                      style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    pw.SizedBox(height: 8),
                    pw.Wrap(
                      spacing: 16,
                      runSpacing: 6,
                      children: _convenios.map((convenio) {
                        final faturamento =
                            faturamentoPorFila[convenio.nome] ?? 0.0;
                        if (faturamento == 0) return pw.SizedBox.shrink();
                        return _buildLegendaPizzaRowPDF(
                          color: PdfColor.fromInt(convenio.cor.value),
                          texto:
                              '${convenio.nome} - R\$ ${faturamento.toStringAsFixed(2)}',
                        );
                      }).toList(),
                    ),
                  ] else
                    pw.Text(
                      'Nenhum faturamento no mês.',
                      style: const pw.TextStyle(color: PdfColors.grey),
                    ),
                ],
              ),
            ),
            pw.SizedBox(height: 0.5 * PdfPageFormat.cm),
            // Gráfico de Distribuição Horária
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey300),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'Distribuição Horária',
                    style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      color: corSecundaria,
                    ),
                  ),
                  pw.SizedBox(height: 10),
                  if (horasComAtendimento.isNotEmpty)
                    ...horasComAtendimento.map((hora) {
                      final quantidade = consultasPorHora[hora]!;
                      final fatorLargura = quantidade / maxConsultasNaHora;
                      return pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(vertical: 2),
                        child: _buildBarraHorariaRowPDF(
                          hora: '$hora:00',
                          quantidade: quantidade,
                          fatorLargura: fatorLargura,
                          cor: corPrimaria,
                        ),
                      );
                    })
                  else
                    pw.Text(
                      'Nenhum atendimento no mês.',
                      style: const pw.TextStyle(color: PdfColors.grey),
                    ),
                ],
              ),
            ),
            pw.SizedBox(height: 1.0 * PdfPageFormat.cm),

            // Tabela de Histórico
            pw.Text(
              'Histórico Detalhado',
              style: pw.TextStyle(
                fontSize: 20,
                fontWeight: pw.FontWeight.bold,
                color: corPrimaria,
              ),
            ),
            pw.SizedBox(height: 0.5 * PdfPageFormat.cm),
            if (consultasDoMes.isEmpty)
              pw.Text(
                'Nenhum atendimento registrado neste mês.',
                style: const pw.TextStyle(color: PdfColors.grey),
              )
            else
              pw.Table.fromTextArray(
                headerStyle: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.white,
                ),
                headerDecoration: pw.BoxDecoration(color: corPrimaria),
                cellHeight: 25,
                cellAlignments: {
                  0: pw.Alignment.centerLeft,
                  1: pw.Alignment.center,
                  2: pw.Alignment.centerLeft,
                  3: pw.Alignment.centerRight,
                },
                headers: <String>[
                  'Data',
                  'Hora',
                  'Fila/Convênio',
                  'Valor (R\$)',
                ],
                data: <List<String>>[
                  ...consultasDoMes.map(
                    (ConsultaRegistro c) => [
                      '${c.hora.day.toString().padLeft(2, "0")}/${c.hora.month.toString().padLeft(2, "0")}',
                      '${c.hora.hour.toString().padLeft(2, "0")}:${c.hora.minute.toString().padLeft(2, "0")}',
                      c.nomeConvenio,
                      c.valor.toStringAsFixed(2).replaceAll('.', ','),
                    ],
                  ),
                ],
              ),
          ];
        },
      ),
    );

    // 3. Salvar e Compartilhar/Abrir

    try {
      final pdfBytes = await pdf.save();
      final fileName = 'Faturamento_Amil_${agora.month}_${agora.year}.pdf';

      // Lógica condicional para salvar o arquivo
      if (Platform.isAndroid || Platform.isIOS) {
        // Em dispositivos móveis, usar a tela de compartilhamento
        final tempDir = await getTemporaryDirectory();
        final filePath = '${tempDir.path}/$fileName';
        final file = File(filePath);
        await file.writeAsBytes(pdfBytes);

        final xFile = XFile(filePath, name: fileName);
        await Share.shareXFiles(
          [xFile],
          text:
              'Relatório de Faturamento - Telemedicina Amil (${agora.month}/${agora.year})',
        );
      } else {
        // Em Desktop (Windows, Linux, macOS), usar o diálogo "Salvar como..."
        String? outputFile = await FilePicker.platform.saveFile(
          dialogTitle: 'Salvar Relatório PDF',
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: ['pdf'],
        );

        if (outputFile != null) {
          final file = File(outputFile);
          await file.writeAsBytes(pdfBytes);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Colors.green,
              content: Text('✅ Relatório PDF salvo com sucesso!'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro ao gerar PDF: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // --- WIDGETS AUXILIARES PARA PDF ---

  pw.Widget _buildResumoRowPDF(
    String label,
    String valor, {
    pw.TextStyle? labelStyle,
    pw.TextStyle? valorStyle,
    PdfColor? valorColor,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: labelStyle ?? const pw.TextStyle(fontSize: 12)),
          pw.Text(
            valor,
            style:
                valorStyle ??
                pw.TextStyle(
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                  color: valorColor,
                ),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildLegendaPizzaRowPDF({
    required PdfColor color,
    required String texto,
  }) {
    return pw.Row(
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        pw.Container(width: 12, height: 12, color: color),
        pw.SizedBox(width: 8),
        pw.Text(texto, style: const pw.TextStyle(fontSize: 9)),
      ],
    );
  }

  pw.Widget _buildBarraHorariaRowPDF({
    required String hora,
    required int quantidade,
    required double fatorLargura,
    required PdfColor cor,
  }) {
    return pw.Row(
      children: [
        pw.SizedBox(
          width: 35,
          child: pw.Text(hora, style: const pw.TextStyle(fontSize: 9)),
        ),
        pw.Expanded(
          child: pw.LayoutBuilder(
            builder: (context, constraints) {
              return pw.Container(
                height: 12,
                decoration: const pw.BoxDecoration(
                  color: PdfColors.grey200,
                  borderRadius: pw.BorderRadius.all(pw.Radius.circular(6)),
                ),
                child: pw.Align(
                  alignment: pw.Alignment.centerLeft,
                  child: pw.Container(
                    width: (constraints?.maxWidth ?? 0) * fatorLargura,
                    decoration: pw.BoxDecoration(
                      color: cor,
                      borderRadius: const pw.BorderRadius.all(
                        pw.Radius.circular(6),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        pw.SizedBox(
          width: 25,
          child: pw.Text(
            '$quantidade',
            textAlign: pw.TextAlign.right,
            style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          ),
        ),
      ],
    );
  }

  // --- PERSISTÊNCIA DE DADOS ---
  Future<void> _salvarDados() async {
    final prefs = await SharedPreferences.getInstance();

    // Salvar histórico de consultas (convertido para JSON)
    final historicoJson = jsonEncode(
      _historicoConsultas
          .map(
            (c) => {
              // Inclui o 'id' na serialização
              'id': c.id,
              'fila': c.nomeConvenio,
              'valor': c.valor,
              'hora': c.hora.toIso8601String(),
              'modificadoEm': c.modificadoEm.toIso8601String(),
            },
          )
          .toList(),
    );
    await prefs.setString('historico_consultas', historicoJson);

    // Salvar metas e tema
    await prefs.setDouble('meta_diaria', metaDiaria);
    await prefs.setDouble('meta_mensal', metaMensal);
    await prefs.setString('tema_selecionado', _temaSelecionado);
    await prefs.setDouble('taxa_desconto', taxaDesconto);
    await prefs.setInt('sync_port', _syncPort);

    // Salvar configurações de sync automático
    await prefs.setBool('sync_automatico_ativo', _syncAutomaticoAtivo);
    if (_parceiroSyncIp != null) {
      await prefs.setString('parceiro_sync_ip', _parceiroSyncIp!);
    }

    // Salvar convênios
    final conveniosJson = jsonEncode(
      _convenios.map((c) => c.toJson()).toList(),
    );
    await prefs.setString('convenios', conveniosJson);

    // Salvar histórico de plantões
    final plantoesJson = jsonEncode(
      _historicoPlantoes
          .map(
            (p) => {
              'id': p.id,
              'chamei5Pacientes': p.chamei5Pacientes,
              'pacientesAdicionais': p.pacientesAdicionais,
              'valorTotal': p.valorTotal,
              'hora': p.hora.toIso8601String(),
              'modificadoEm': p.modificadoEm.toIso8601String(),
            },
          )
          .toList(),
    );
    await prefs.setString('historico_plantoes', plantoesJson);

    print('💾 Dados salvos localmente.');

    // Dispara a sincronização automática se ativa
    _sincronizacaoAutomatica();
  }

  Future<void> _carregarDados() async {
    final prefs = await SharedPreferences.getInstance();

    // Carregar histórico de consultas
    final historicoJson = prefs.getString('historico_consultas');
    if (historicoJson != null) {
      final List<dynamic> historicoDecoded = jsonDecode(historicoJson);
      _historicoConsultas.clear();
      _historicoConsultas.addAll(
        historicoDecoded.map(
          (item) => ConsultaRegistro(
            id:
                item['id'] ??
                UniqueKey()
                    .toString(), // Carrega 'id' ou gera um novo para compatibilidade
            nomeConvenio: item['fila'],
            valor: item['valor'],
            hora: DateTime.parse(item['hora']),
            modificadoEm: item['modificadoEm'] != null
                ? DateTime.parse(item['modificadoEm'])
                : DateTime.parse(item['hora']), // Fallback para dados antigos
          ),
        ),
      );
    }

    // Carregar histórico de plantões
    final plantoesJsonString = prefs.getString('historico_plantoes');
    if (plantoesJsonString != null) {
      final List<dynamic> plantoesDecoded = jsonDecode(plantoesJsonString);
      _historicoPlantoes.clear();
      _historicoPlantoes.addAll(
        plantoesDecoded.map(
          (item) => PlantaoRegistro(
            id: item['id'] ?? UniqueKey().toString(),
            chamei5Pacientes: item['chamei5Pacientes'],
            pacientesAdicionais: item['pacientesAdicionais'],
            valorTotal: item['valorTotal'],
            hora: DateTime.parse(item['hora']),
            modificadoEm: DateTime.parse(item['modificadoEm'] ?? item['hora']),
          ),
        ),
      );
    }

    // Carregar metas e tema
    metaDiaria = prefs.getDouble('meta_diaria') ?? 0.0;
    metaMensal = prefs.getDouble('meta_mensal') ?? 0.0;
    _temaSelecionado = prefs.getString('tema_selecionado') ?? 'rosa';
    taxaDesconto = prefs.getDouble('taxa_desconto') ?? 0.158;
    _syncPort = prefs.getInt('sync_port') ?? 8080;

    // Carregar configurações de sync automático
    _syncAutomaticoAtivo = prefs.getBool('sync_automatico_ativo') ?? false;
    _parceiroSyncIp = prefs.getString('parceiro_sync_ip');

    // Carregar convênios
    final conveniosJson = prefs.getString('convenios');
    if (conveniosJson != null) {
      final List<dynamic> conveniosDecoded = jsonDecode(conveniosJson);
      _convenios = conveniosDecoded
          .map((item) => Convenio.fromJson(item))
          .toList();
    } else {
      // Se não houver convênios salvos, carrega os padrões
      _convenios = _getConveniosPadrao();
    }

    // Atualizar controllers de texto
    _metaDiariaController.text = metaDiaria > 0 ? metaDiaria.toString() : '';
    _metaMensalController.text = metaMensal > 0 ? metaMensal.toString() : '';
    _taxaDescontoController.text = taxaDesconto > 0
        ? (taxaDesconto * 100).toStringAsFixed(1)
        : '';
    _syncPortController.text = _syncPort.toString();

    setState(() {});
    print('✅ Dados carregados.');
  }

  // --- LÓGICA DE BACKUP / IP ---
  Future<void> _obterIpLocal() async {
    try {
      final info = NetworkInfo();
      String? ip = await info.getWifiIP();

      if (ip == null || ip.isEmpty) {
        // Tenta obter do hostname como fallback
        ip = InternetAddress.loopbackIPv4.host;
      }

      setState(() {
        meuIpLocal = ip ?? "Não conectado";
      });
      print('📍 IP Local: $meuIpLocal');
    } catch (e) {
      print('⚠️ Erro ao obter IP: $e');
      setState(() {
        meuIpLocal = "Erro ao obter IP";
      });
    }
  }

  Future<void> _getDeviceName() async {
    final deviceInfo = DeviceInfoPlugin();
    String name = 'Dispositivo'; // Fallback name
    try {
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        // Combina marca e modelo para um nome mais descritivo
        final brand = androidInfo.brand;
        final model = androidInfo.model;
        name = '${brand[0].toUpperCase()}${brand.substring(1)} $model';
      } else if (Platform.isWindows) {
        name = (await deviceInfo.windowsInfo).computerName;
      } else if (Platform.isIOS) {
        // Em iOS, 'name' é o nome definido pelo usuário (ex: "iPhone de Thiago")
        name = (await deviceInfo.iosInfo).name;
      }
    } catch (e) {
      print('⚠️ Erro ao obter nome do dispositivo: $e');
      // O nome 'Dispositivo' será usado como fallback
    }

    if (mounted) {
      setState(() => _deviceName = name.trim());
    }
  }

  // --- SINCRONIZAÇÃO E BACKUP ---
  Map<String, dynamic> _exportarDados() {
    return {
      'deviceName': _deviceName,
      'timestamp': DateTime.now().toIso8601String(),
      'consultas': _historicoConsultas
          .map(
            (c) => {
              'id': c.id, // Inclui o 'id' na exportação
              'fila': c.nomeConvenio,
              'valor': c.valor,
              'hora': c.hora.toIso8601String(),
              'modificadoEm': c.modificadoEm.toIso8601String(),
            },
          )
          .toList(),
      'plantoes': _historicoPlantoes
          .map(
            (p) => {
              'id': p.id,
              'chamei5Pacientes': p.chamei5Pacientes,
              'pacientesAdicionais': p.pacientesAdicionais,
              'valorTotal': p.valorTotal,
              'hora': p.hora.toIso8601String(),
              'modificadoEm': p.modificadoEm.toIso8601String(),
            },
          )
          .toList(),
      'convenios': _convenios.map((c) => c.toJson()).toList(),
      'metaDiaria': metaDiaria,
      'metaMensal': metaMensal,
      'taxaDesconto': taxaDesconto,
    };
  }

  void _importarDados(Map<String, dynamic> dados, {bool mesclar = true}) {
    // --- LÓGICA DE MERGE DE DADOS ---
    final List<ConsultaRegistro> registrosRemotos = [];
    final List<PlantaoRegistro> plantoesRemotos = [];
    if (dados['plantoes'] != null) {
      for (var p in dados['plantoes']) {
        plantoesRemotos.add(
          PlantaoRegistro(
            id: p['id'] ?? UniqueKey().toString(),
            chamei5Pacientes: p['chamei5Pacientes'],
            pacientesAdicionais: p['pacientesAdicionais'],
            valorTotal: p['valorTotal'],
            hora: DateTime.parse(p['hora']),
            modificadoEm: p['modificadoEm'] != null
                ? DateTime.parse(p['modificadoEm'])
                : DateTime.parse(p['hora']),
          ),
        );
      }
    }
    if (dados['consultas'] != null) {
      for (var c in dados['consultas']) {
        registrosRemotos.add(
          ConsultaRegistro(
            // Carrega 'id' ou gera um novo para compatibilidade
            id: c['id'] ?? UniqueKey().toString(),
            nomeConvenio: c['fila'],
            valor: c['valor'],
            hora: DateTime.parse(c['hora']),
            modificadoEm: c['modificadoEm'] != null
                ? DateTime.parse(c['modificadoEm'])
                : DateTime.parse(c['hora']), // Fallback para dados antigos
          ),
        );
      }
    }

    // --- LÓGICA DE MERGE DE CONVÊNIOS ---
    final List<Convenio> conveniosRemotos = [];
    if (dados['convenios'] != null) {
      for (var c in dados['convenios']) {
        conveniosRemotos.add(Convenio.fromJson(c as Map<String, dynamic>));
      }
    }

    // NOVO: Lógica para adicionar filas (convênios) ausentes do arquivo de backup.
    // Isso garante que dados de filas antigas fiquem visíveis após a importação.
    final Set<String> nomesConveniosAtuais = {
      ..._convenios.map((c) => c.nome),
      ...conveniosRemotos.map((c) => c.nome),
    };
    final Set<String> nomesConveniosNosRegistros = registrosRemotos
        .map((c) => c.nomeConvenio)
        .toSet();

    final conveniosParaAdicionar = <Convenio>[];
    for (final nomeRemoto in nomesConveniosNosRegistros) {
      if (!nomesConveniosAtuais.contains(nomeRemoto)) {
        // Cria um novo convênio com valores padrão se ele não existir
        print('ℹ️ Fila "$nomeRemoto" não encontrada. Adicionando...');
        conveniosParaAdicionar.add(
          Convenio(
            id: nomeRemoto.toLowerCase().replaceAll(
              ' ',
              '_',
            ), // Gera um ID simples
            nome: nomeRemoto,
            valor: 0.0, // Valor padrão, pode ser editado depois
            cor: Colors.grey, // Cor padrão
          ),
        );
      }
    }

    if (conveniosParaAdicionar.isNotEmpty) {
      // Adiciona os novos convênios à lista de remotos para serem mesclados
      conveniosRemotos.addAll(conveniosParaAdicionar);
    }

    final List<ConsultaRegistro> listaFinal;
    final List<Convenio> conveniosFinais;

    if (mesclar) {
      // --- LÓGICA DE MERGE INTELIGENTE (Last Write Wins) ---
      // Combina as listas e usa um mapa para resolver conflitos.
      final historicoCombinado = [..._historicoConsultas, ...registrosRemotos];
      final mapaRegistros = <String, ConsultaRegistro>{};

      for (final novoRegistro in historicoCombinado) {
        final registroExistente = mapaRegistros[novoRegistro.id];

        // Se não existe ou se o novo é mais recente, substitui.
        if (registroExistente == null ||
            novoRegistro.modificadoEm.isAfter(registroExistente.modificadoEm)) {
          mapaRegistros[novoRegistro.id] = novoRegistro;
        }
      }
      listaFinal = mapaRegistros.values.toList();

      // Merge de Convênios, priorizando o remoto em caso de conflito de ID
      final mapaConvenios = <String, Convenio>{};
      // Adiciona os locais primeiro
      for (final convenio in _convenios) {
        mapaConvenios[convenio.id] = convenio;
      }
      // Adiciona/sobrescreve com os remotos
      for (final convenio in conveniosRemotos) {
        mapaConvenios[convenio.id] = convenio;
      }
      conveniosFinais = mapaConvenios.values.toList();
    } else {
      // Apenas substitui os dados locais pelos remotos
      listaFinal = registrosRemotos;
      conveniosFinais = conveniosRemotos;
    }
    listaFinal.sort((a, b) => b.hora.compareTo(a.hora));

    setState(() {
      _historicoConsultas.clear();
      _historicoConsultas.addAll(listaFinal);

      _convenios.clear();
      _convenios.addAll(conveniosFinais);

      metaDiaria = dados['metaDiaria'] ?? 0.0;
      metaMensal = dados['metaMensal'] ?? 0.0;
      taxaDesconto = dados['taxaDesconto'] ?? 0.158;
    });

    if (conveniosParaAdicionar.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.blue,
          content: Text(
            'ℹ️ ${conveniosParaAdicionar.length} nova(s) fila(s) foi/foram adicionada(s) a partir do backup. Você pode editá-la(s) no gerenciador de filas.',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    }
    _salvarDados(); // Salva os dados importados
  }

  Future<String> _getRemoteIp(Request request) async {
    final connectionInfo = request.context['shelf.io.connectionInfo'];
    if (connectionInfo is HttpConnectionInfo) {
      return connectionInfo.remoteAddress.address;
    }
    return 'desconhecido';
  }

  // Usamos um Completer para aguardar a resposta do usuário na UI thread.
  Completer<bool>? _confirmationCompleter;

  Future<bool> _confirmarConexaoRemota(String remoteIp) async {
    if (_ipSincronizacaoAutorizado == remoteIp &&
        _autorizacaoExpira != null &&
        DateTime.now().isBefore(_autorizacaoExpira!)) {
      return true;
    }

    if (_confirmationCompleter != null &&
        !_confirmationCompleter!.isCompleted) {
      // Já existe uma solicitação em andamento.
      return false;
    }

    _confirmationCompleter = Completer<bool>();

    // Garante que o diálogo seja exibido na UI thread principal.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _confirmationCompleter?.complete(false);
        return;
      }
      final autorizado = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Solicitação de Sincronização'),
          content: Text(
            'O dispositivo $remoteIp deseja sincronizar dados com este aparelho.\n\nDeseja aceitar a conexão?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Recusar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Aceitar'),
            ),
          ],
        ),
      );
      _confirmationCompleter?.complete(autorizado ?? false);
    });

    final aceita = await _confirmationCompleter!.future;

    if (aceita) {
      _ipSincronizacaoAutorizado = remoteIp;
      _autorizacaoExpira = DateTime.now().add(const Duration(minutes: 5));
    }
    return aceita;
  }

  Future<void> _pararServidorSincronizacao() async {
    if (_server != null) {
      await _server!.close(force: true);
      setState(() {
        if (_registration != null) {
          // Para o anúncio do serviço na rede
          unregister(_registration!);
          _registration = null;
        }
        _server = null;
      });
      print('🛑 Servidor parado.');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.orange,
          content: Text('🛑 Sincronização desativada.'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _iniciarServidorSincronizacao({
    void Function(void Function())? modalSetState,
  }) async {
    if (_server != null) {
      print('ℹ️ Servidor já está ativo.');
      return;
    }

    final router = shelf_router.Router();

    // Endpoint para exportar dados (GET)
    router.get('/exportar', (Request request) async {
      final remoteIp = await _getRemoteIp(request);
      final autorizado = await _confirmarConexaoRemota(remoteIp);

      if (!autorizado) {
        return Response.forbidden(
          jsonEncode({
            'status': 'rejeitado',
            'mensagem': 'Conexão recusada pelo usuário.',
          }),
          headers: {'content-type': 'application/json'},
        );
      }

      return Response.ok(
        jsonEncode(_exportarDados()),
        headers: {'content-type': 'application/json'},
      );
    });

    // Endpoint para importar dados (POST)
    router.post('/importar', (Request request) async {
      final remoteIp = await _getRemoteIp(request);
      if (_ipSincronizacaoAutorizado != remoteIp ||
          _autorizacaoExpira == null ||
          DateTime.now().isAfter(_autorizacaoExpira!)) {
        return Response.forbidden(
          jsonEncode({
            'status': 'rejeitado',
            'mensagem': 'Importação não autorizada.',
          }),
          headers: {'content-type': 'application/json'},
        );
      }

      try {
        final payload = await request.readAsString();
        final dados = jsonDecode(payload);
        _importarDados(dados, mesclar: false); // No POST, sempre sobrescreve
        return Response.ok(
          jsonEncode({'status': 'sucesso', 'mensagem': 'Dados importados!'}),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'status': 'erro', 'mensagem': '$e'}),
          headers: {'content-type': 'application/json'},
        );
      }
    });

    try {
      _server = await shelf_io.serve(
        router.call,
        InternetAddress.anyIPv4,
        _syncPort,
        shared: true,
      );
      print('✅ Servidor iniciado em: $meuIpLocal:$_syncPort');

      // Anuncia o serviço na rede local
      _registration = await register(
        Service(name: _deviceName, type: '_controleamil._tcp', port: _syncPort),
      );
      print('📢 Serviço anunciado na rede: $_deviceName');

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green,
          content: Text('✅ Servidor ativo: $meuIpLocal:$_syncPort'),
          duration: const Duration(seconds: 2),
        ),
      );

      // Atualiza o estado da tela principal e da modal, se estiver aberta
      setState(() {});
      modalSetState?.call(() {});
    } catch (e) {
      print('❌ Erro ao iniciar servidor: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red,
          content: Text('❌ Erro: $e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _sincronizarComDispositivo(
    String modo, {
    void Function(void Function())? modalSetState,
  }) async {
    final ipDestino = _ipDestinoController.text.trim();
    if (ipDestino.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.orange,
          content: Text('⚠️ Digite o IP do outro aparelho'),
        ),
      );
      return;
    }

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);

      // 1. Verificar se o servidor remoto está acessível
      print('🔍 Tentando conectar a $ipDestino:$_syncPort...');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.blue,
          content: Text('🔄 Conectando ao outro dispositivo...'),
          duration: Duration(seconds: 2),
        ),
      );

      // 2. Buscar dados do outro dispositivo
      final requestGet = await client.getUrl(
        Uri.parse('http://$ipDestino:$_syncPort/exportar'),
      );
      final responseGet = await requestGet.close();

      // Verificar status HTTP
      if (responseGet.statusCode != 200) {
        print('❌ Status HTTP: ${responseGet.statusCode}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red,
            content: Text(
              '❌ Erro: Servidor respondeu com status ${responseGet.statusCode}\n'
              'Verifique se o servidor está ativo no outro dispositivo',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
        return;
      }

      final bodyGet = await responseGet.transform(utf8.decoder).join();
      print('📥 Resposta recebida: $bodyGet');

      // Validar se é JSON
      if (!bodyGet.trim().startsWith('{')) {
        print('❌ Resposta não é JSON válido');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.red,
            content: Text(
              '❌ Erro: Resposta inválida\n'
              'Certifique-se de que conectou ao IP correto',
            ),
            duration: Duration(seconds: 4),
          ),
        );
        return;
      }

      final dadosRemoto = jsonDecode(bodyGet);

      final nomeDispositivoRemoto =
          dadosRemoto['deviceName'] ?? 'Dispositivo Remoto';

      // 3. Mostrar diálogo de confirmação
      final confirmado = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            modo == 'push' ? 'Confirmar Envio' : 'Confirmar Recebimento',
          ),
          content: Text(
            modo == 'push'
                ? 'Deseja ENVIAR os dados de "$_deviceName" e SOBRESCREVER os dados em "$nomeDispositivoRemoto"?'
                : 'Deseja RECEBER os dados de "$nomeDispositivoRemoto" e SOBRESCREVER os dados em "$_deviceName"?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('Confirmar'),
            ),
          ],
        ),
      );

      if (confirmado != true) {
        print('Sincronização cancelada pelo usuário.');
        return;
      }

      if (modo == 'push') {
        // 4. Enviar dados locais para sobrescrever os remotos
        print('📤 Enviando dados locais (push)...');
        final requestPost = await client.postUrl(
          Uri.parse('http://$ipDestino:$_syncPort/importar'),
        );
        requestPost.headers.set('content-type', 'application/json');
        requestPost.add(utf8.encode(jsonEncode(_exportarDados())));
        final responsePost = await requestPost.close();

        if (responsePost.statusCode != 200) {
          throw Exception('Erro ao enviar dados: ${responsePost.statusCode}');
        }
      } else {
        // modo 'pull'
        // 4. Importar dados remotos, sobrescrevendo os locais
        _importarDados(dadosRemoto, mesclar: false);
      }

      // 5. Salva o IP do parceiro para sync automático e finaliza
      setState(() {
        _parceiroSyncIp = ipDestino;
      });
      _salvarDados();

      print('✅ Sincronização ($modo) concluída!');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green,
          content: Text(
            modo == 'push'
                ? '✅ Dados enviados com sucesso!'
                : '✅ Dados recebidos e atualizados com sucesso!',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      print('❌ Erro ao sincronizar: $e');
      String mensagemErro = '$e';

      if (e.toString().contains('Connection refused')) {
        mensagemErro =
            'Conexão recusada\nO servidor não está ativo no IP informado';
      } else if (e.toString().contains('Connection timed out')) {
        mensagemErro = 'Tempo expirado\nO dispositivo não respondeu a tempo';
      } else if (e.toString().contains('Unable to parse')) {
        mensagemErro = 'Erro ao processar dados\nVerifique a compatibilidade';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red,
          content: Text('❌ Erro: $mensagemErro'),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _sincronizacaoAutomatica() async {
    if (!_syncAutomaticoAtivo ||
        _parceiroSyncIp == null ||
        _parceiroSyncIp!.isEmpty) {
      return;
    }

    print('🔄 Iniciando sincronização automática com $_parceiroSyncIp...');

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);

      // 1. Buscar dados do parceiro
      final requestGet = await client.getUrl(
        Uri.parse('http://$_parceiroSyncIp:$_syncPort/exportar'),
      );
      // Para sync automático, não precisamos de confirmação de diálogo,
      // mas o servidor ainda precisa estar ativo.
      final responseGet = await requestGet.close();
      if (responseGet.statusCode != 200) return;
      final bodyGet = await responseGet.transform(utf8.decoder).join();
      final dadosRemoto = jsonDecode(bodyGet);

      // 2. Enviar dados locais
      final requestPost = await client.postUrl(
        Uri.parse('http://$_parceiroSyncIp:$_syncPort/importar'),
      );
      requestPost.headers.set('content-type', 'application/json');
      requestPost.add(utf8.encode(jsonEncode(_exportarDados())));
      await requestPost.close();

      // 3. Importar dados recebidos
      _importarDados(dadosRemoto, mesclar: true); // Sync auto sempre mescla
      print('✅ Sincronização automática concluída com sucesso.');
    } catch (e) {
      print('⚠️ Falha na sincronização automática: $e');
    }
  }

  Discovery? _activeDiscovery;
  Future<void> _discoverServices({
    void Function(void Function())? modalSetState,
  }) async {
    if (_isDiscovering) {
      await _stopDiscovery();
      return;
    }

    setState(() {
      _isDiscovering = true;
      _discoveredServices.clear();
    });

    try {
      final discovery = await startDiscovery(
        '_controleamil._tcp',
        ipLookupType: IpLookupType.v4,
      );
      _activeDiscovery = discovery;

      // O objeto Discovery funciona como um ChangeNotifier.
      // Sempre que um serviço for descoberto ou sumir, ele chama esse listener.
      discovery.addListener(() {
        if (!mounted) return;
        // Defer state updates to avoid calling setState during a build, which can cause exceptions.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            final newServices = <Service>[];
            for (var service in discovery.services) {
              // Evita adicionar o próprio dispositivo na lista
              if (service.host != meuIpLocal) {
                newServices.add(service);
              }
            }
            // Use setState on the main state
            setState(() {
              _discoveredServices.clear();
              // Use a Set to easily remove duplicates before converting back to a List
              _discoveredServices.addAll(newServices.toSet().toList());
            });
            // Trigger a rebuild on the modal if it's open
            modalSetState?.call(() {});
          }
        });
      });
    } catch (e) {
      print('❌ Falha ao iniciar descoberta: $e');
      _stopDiscovery();
    }
  }

  Future<void> _stopDiscovery() async {
    if (_activeDiscovery != null) {
      try {
        await stopDiscovery(_activeDiscovery!);
      } catch (e) {
        print('⚠️ Erro ao parar discovery do nsd: $e');
      }
      _activeDiscovery = null;
    }

    setState(() => _isDiscovering = false);
  }

  Future<void> _exportarParaArquivoJson() async {
    try {
      final dados = _exportarDados();
      final jsonString = const JsonEncoder.withIndent('  ').convert(dados);
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .substring(0, 19);
      final fileName = 'controle_amil_backup_$timestamp.json';

      // Lógica condicional para salvar o arquivo
      if (Platform.isAndroid || Platform.isIOS) {
        // Em dispositivos móveis, usar a tela de compartilhamento
        final tempDir = await getTemporaryDirectory();
        final filePath = '${tempDir.path}/$fileName';
        final file = File(filePath);
        await file.writeAsString(jsonString);

        final xFile = XFile(filePath, name: fileName);
        await Share.shareXFiles([
          xFile,
        ], text: 'Backup dos dados do Controle Amil');
        print('✅ Arquivo de backup compartilhado: $filePath');
      } else {
        // Em Desktop (Windows, Linux, macOS), usar o diálogo "Salvar como..."
        String? outputFile = await FilePicker.platform.saveFile(
          dialogTitle: 'Salvar Backup',
          fileName: fileName,
        );

        if (outputFile != null) {
          final file = File(outputFile);
          await file.writeAsString(jsonString);
          print('✅ Arquivo de backup salvo em: $outputFile');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Colors.green,
              content: Text('✅ Backup salvo com sucesso!'),
              duration: Duration(seconds: 3),
            ),
          );
        } else {
          // Usuário cancelou o diálogo
          print('Operação de salvar arquivo cancelada pelo usuário.');
        }
      }
    } catch (e) {
      print('❌ Erro ao exportar arquivo: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red,
          content: Text('❌ Erro ao exportar arquivo: $e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _importarDeArquivoJson() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result == null || result.files.single.path == null) {
        // Usuário cancelou o seletor
        return;
      }

      final file = File(result.files.single.path!);
      final jsonString = await file.readAsString();
      final dados = jsonDecode(jsonString);

      _importarDados(dados);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green,
          content: Text(
            '✅ Dados importados com sucesso do arquivo ${result.files.single.name}!',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      print('❌ Erro ao importar arquivo: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red,
          content: Text('❌ Erro ao importar arquivo: $e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  // --- LÓGICA DE NEGÓCIO (CÁLCULOS DINÂMICOS) ---
  void _registrarPlantao() {
    final adicionaisText = _pacientesAdicionaisController.text.trim();
    final adicionais = int.tryParse(adicionaisText) ?? 0;

    final valorTotal =
        (_chamei5Pacientes ? _valorBasePlantao : 0.0) +
        (adicionais * _valorAdicionalPlantao);

    if (valorTotal == 0) return; // Evita registrar plantão vazio

    setState(() {
      _historicoPlantoes.insert(
        0,
        PlantaoRegistro(
          id: UniqueKey().toString(),
          chamei5Pacientes: _chamei5Pacientes,
          pacientesAdicionais: adicionais,
          valorTotal: valorTotal,
          hora: DateTime.now(),
          modificadoEm: DateTime.now(),
        ),
      );

      // Limpa os campos após registrar
      _chamei5Pacientes = false;
      _pacientesAdicionaisController.clear();
      _salvarDados();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('✅ Plantão registrado com sucesso!'),
        backgroundColor: Colors.green,
      ),
    );
  }

  Widget _buildRegistroPlantoesCard(bool isMobile) {
    final hoje = DateTime.now();
    final plantoesHoje = _historicoPlantoes.where(
      (p) =>
          p.hora.day == hoje.day &&
          p.hora.month == hoje.month &&
          p.hora.year == hoje.year,
    );
    final plantoesMes = _historicoPlantoes.where(
      (p) => p.hora.month == hoje.month && p.hora.year == hoje.year,
    );

    final qtdHoje = plantoesHoje.length;
    final receitaHoje = plantoesHoje.fold(0.0, (s, p) => s + p.valorTotal);
    final qtdMes = plantoesMes.length;
    final receitaMes = plantoesMes.fold(0.0, (s, p) => s + p.valorTotal);

    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.schedule_outlined, size: 20, color: Colors.black87),
              SizedBox(width: 8),
              Text(
                'Registro de Plantões',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(
                0xFFF8F9FA,
              ), // Cor de fundo suave idêntica à imagem
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: _chamei5Pacientes,
                        onChanged: (val) {
                          setState(() => _chamei5Pacientes = val ?? false);
                        },
                        activeColor: temaAtual.cor1,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Chamei 5 pacientes por hora (R\$ 100,00 )',
                        style: TextStyle(fontSize: 13, color: Colors.black87),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  'Pacientes adicionais (R\$ 7,00 cada)',
                  style: TextStyle(fontSize: 13, color: Colors.black87),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _pacientesAdicionaisController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    hintText: '0',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade200),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade200),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: _registrarPlantao,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.black87,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('Registrar Plantão'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _buildResumoPlantaoRow('Plantões hoje:', qtdHoje.toString()),
          const SizedBox(height: 12),
          _buildResumoPlantaoRow(
            'Receita hoje:',
            'R\$ ${receitaHoje.toStringAsFixed(2).replaceAll('.', ',')}',
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Divider(height: 1, thickness: 1, color: Colors.black12),
          ),
          _buildResumoPlantaoRow('Plantões no mês:', qtdMes.toString()),
          const SizedBox(height: 12),
          _buildResumoPlantaoRow(
            'Receita mensal:',
            'R\$ ${receitaMes.toStringAsFixed(2).replaceAll('.', ',')}',
          ),
        ],
      ),
    );
  }

  Widget _buildResumoPlantaoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
        ),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
      ],
    );
  }

  // Adicionar nova consulta manualmente ao painel
  void _registrarConsulta(String nomeConvenio, double valor) {
    setState(() {
      _historicoConsultas.insert(
        0,
        // Gera um ID único para cada nova consulta
        ConsultaRegistro(
          // Na criação, hora e modificadoEm são iguais
          id: UniqueKey().toString(),
          nomeConvenio: nomeConvenio,
          valor: valor,
          hora: DateTime.now(),
          modificadoEm: DateTime.now(),
        ),
      );
      _salvarDados();
    });
  }

  void _removerRegistro(int index) {
    if (index < 0 || index >= _historicoConsultas.length) return;
    final item = _historicoConsultas[index];
    setState(() {
      _historicoConsultas.removeAt(index);
      _salvarDados();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Registro ${item.nomeConvenio} removido.'),
        backgroundColor: Colors.orange,
      ),
    );
  }

  Future<void> _zerarHistorico() async {
    if (_historicoConsultas.isEmpty) {
      return;
    }

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Zerar histórico'),
          content: const Text(
            'Deseja realmente apagar todos os registros de atendimento?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Apagar tudo'),
            ),
          ],
        );
      },
    );

    if (confirmar == true) {
      setState(() {
        _historicoConsultas.clear();
        _salvarDados();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Histórico zerado com sucesso.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // Contadores por categoria
  int get totalConsultasHoje {
    final hoje = DateTime.now();
    return _historicoConsultas.where((c) {
      return c.hora.day == hoje.day &&
          c.hora.month == hoje.month &&
          c.hora.year == hoje.year;
    }).length;
  }

  int totalPorFilaHoje(String nomeConvenio) {
    final hoje = DateTime.now();
    return _historicoConsultas.where((c) {
      return c.nomeConvenio == nomeConvenio &&
          c.hora.day == hoje.day &&
          c.hora.month == hoje.month &&
          c.hora.year == hoje.year;
    }).length;
  }

  // Soma de faturamento bruto
  double get receitaHojeBruta {
    final hoje = DateTime.now();
    final consultasDeHoje = _historicoConsultas.where((c) {
      return c.hora.day == hoje.day &&
          c.hora.month == hoje.month &&
          c.hora.year == hoje.year;
    });
    return consultasDeHoje.fold(0.0, (soma, item) => soma + item.valor);
  }

  double get receitaMesBruta {
    final hoje = DateTime.now();
    return _historicoConsultas
        .where((c) {
          return c.hora.year == hoje.year && c.hora.month == hoje.month;
        })
        .fold(0.0, (soma, item) => soma + item.valor);
  }

  int get totalConsultasMes {
    final hoje = DateTime.now();
    return _historicoConsultas.where((c) {
      return c.hora.year == hoje.year && c.hora.month == hoje.month;
    }).length;
  }

  // Horas ativas com base nos registros distintos
  int get horasAtivas {
    final hoje = DateTime.now();
    final consultasDeHoje = _historicoConsultas.where((c) {
      return c.hora.day == hoje.day &&
          c.hora.month == hoje.month &&
          c.hora.year == hoje.year;
    });
    final horasUnicas = consultasDeHoje.map((c) => c.hora.hour).toSet();
    return horasUnicas.length;
  }

  // Média de atendimentos por hora
  double get mediaHora {
    if (horasAtivas == 0) return 0.0;
    return totalConsultasHoje / horasAtivas;
  }

  String detalhesPorFaixaHoraria(int horaInicio, DateTime data) {
    final itens = _historicoConsultas.where((c) {
      return c.hora.hour == horaInicio &&
          c.hora.day == data.day &&
          c.hora.month == data.month &&
          c.hora.year == data.year;
    });
    if (itens.isEmpty) return "Nenhum atendimento";

    final Map<String, int> contagemPorFila = {};
    for (var item in itens) {
      contagemPorFila.update(
        item.nomeConvenio,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }
    List<String> partes = [];
    contagemPorFila.forEach((fila, contagem) => partes.add("$fila: $contagem"));

    return partes.join(" | ");
  }

  @override
  Widget build(BuildContext context) {
    // Regra do imposto de 15,8% vista nas imagens e vídeos
    final receitaBrutaMensal = receitaMesBruta;
    double descontoImpostoMensal = receitaBrutaMensal * taxaDesconto;
    double receitaLiquidaMensal = receitaBrutaMensal - descontoImpostoMensal;

    // --- LÓGICA DINÂMICA PARA GRÁFICO DE DISTRIBUIÇÃO HORÁRIA ---
    // 1. Agrupa as consultas do DIA SELECIONADO pela hora em que ocorreram.
    final Map<int, List<ConsultaRegistro>> consultasPorHora = {};
    final consultasDoDiaSelecionado = _historicoConsultas.where(
      (c) =>
          c.hora.day == _analiseDataSelecionada.day &&
          c.hora.month == _analiseDataSelecionada.month &&
          c.hora.year == _analiseDataSelecionada.year,
    );
    for (final consulta in consultasDoDiaSelecionado) {
      consultasPorHora.putIfAbsent(consulta.hora.hour, () => []).add(consulta);
    }

    // 2. Cria uma lista ordenada das horas que tiveram atendimentos.
    final List<int> horasComAtendimento = consultasPorHora.keys.toList()
      ..sort();

    // 3. Calcula o número máximo de consultas em uma única hora para a escala da barra.
    int maxConsultasNaHora = 0;
    if (consultasPorHora.isNotEmpty) {
      maxConsultasNaHora = consultasPorHora.values
          .map((e) => e.length)
          .reduce((a, b) => a > b ? a : b);
    }
    if (maxConsultasNaHora == 0)
      maxConsultasNaHora = 1; // Evita divisão por zero

    // Detectar orientação e tamanho da tela
    final isMobile = MediaQuery.of(context).size.width < 600;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          title: Text(
            'Controle Telemedicina',
            style: TextStyle(
              color: temaAtual.cor1,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Tooltip(
                message: 'Escolher Tema',
                child: GestureDetector(
                  onTap: () => _mostrarSeletorTema(context),
                  child: CircleAvatar(
                    backgroundColor: temaAtual.cor1,
                    child: const Icon(
                      Icons.palette_outlined,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Tooltip(
                message:
                    'Sincronização: ${_server == null ? 'Inativa' : 'Ativa'}',
                child: GestureDetector(
                  onTap: () => _mostrarMenuBackup(context),
                  child: CircleAvatar(
                    backgroundColor: _server == null
                        ? const Color.fromARGB(255, 243, 33, 96)
                        : Colors.green,
                    child: Icon(
                      _server == null
                          ? Icons.sync_disabled_outlined
                          : Icons.cloud_sync_outlined,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Tooltip(
                message: 'Exportar PDF do Mês',
                child: GestureDetector(
                  onTap: _exportarRelatorioMensalPDF,
                  child: const CircleAvatar(
                    backgroundColor: Colors.redAccent,
                    child: Icon(
                      Icons.picture_as_pdf_outlined,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          ],
          bottom: TabBar(
            indicatorColor: temaAtual.cor1,
            labelColor: temaAtual.cor1,
            unselectedLabelColor: Colors.grey,
            tabs: const [
              Tab(icon: Icon(Icons.dashboard_outlined), text: 'Dashboard'),
              Tab(icon: Icon(Icons.analytics_outlined), text: 'Análise'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // --- TAB 1: DASHBOARD ---
            SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(isMobile ? 12.0 : 16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // HEADER COM IP E STATUS
                    Container(
                      width: double.infinity,
                      padding: EdgeInsets.all(isMobile ? 12 : 16),
                      decoration: BoxDecoration(
                        color: temaAtual.cor1.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: temaAtual.cor1.withOpacity(0.3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.info_outline, color: temaAtual.cor1),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Seu IP: ${meuIpLocal ?? "Buscando..."}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: temaAtual.cor2,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Clique no ícone de paleta (canto superior) para escolher tema de cores',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // GRID RESPONSIVO DE METRICAS FINANCEIRAS
                    if (isMobile)
                      Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: _buildMetricCard(
                                  'Consultas Hoje',
                                  '$totalConsultasHoje',
                                  'pacientes',
                                  Icons.groups_outlined,
                                  isMobile,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _buildMetricCard(
                                  'Receita Hoje',
                                  'R\$ ${receitaHojeBruta.toStringAsFixed(2).replaceAll('.', ',')}',
                                  'consultas do dia',
                                  Icons.monetization_on_outlined,
                                  isMobile,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: _buildMetricCard(
                                  'Consultas Mês',
                                  '$totalConsultasMes',
                                  'acumulado',
                                  Icons.calendar_today_outlined,
                                  isMobile,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _buildMetricCard(
                                  'Receita Bruta',
                                  'R\$ ${receitaMesBruta.toStringAsFixed(2).replaceAll('.', ',')}',
                                  'antes impostos',
                                  Icons.account_balance_wallet_outlined,
                                  isMobile,
                                ),
                              ),
                            ],
                          ),
                        ],
                      )
                    else
                      // Mantém o Wrap para telas maiores
                      Row(
                        children: [
                          Expanded(
                            child: _buildMetricCard(
                              'Consultas Hoje',
                              '$totalConsultasHoje',
                              'pacientes',
                              Icons.groups_outlined,
                              isMobile,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildMetricCard(
                              'Receita Hoje',
                              'R\$ ${receitaHojeBruta.toStringAsFixed(2).replaceAll('.', ',')}',
                              'consultas do dia',
                              Icons.monetization_on_outlined,
                              isMobile,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildMetricCard(
                              'Consultas Mês',
                              '$totalConsultasMes',
                              'acumulado',
                              Icons.calendar_today_outlined,
                              isMobile,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildMetricCard(
                              'Receita Bruta',
                              'R\$ ${receitaMesBruta.toStringAsFixed(2).replaceAll('.', ',')}',
                              'antes impostos',
                              Icons.account_balance_wallet_outlined,
                              isMobile,
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 16),

                    // CARD DE RECEITA LÍQUIDA
                    Container(
                      padding: EdgeInsets.all(isMobile ? 12 : 16),
                      decoration: BoxDecoration(
                        color: temaAtual.fundoBatida,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: temaAtual.cor1.withOpacity(0.3),
                        ),
                      ),
                      child: isMobile
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Receita Líquida Mensal',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: temaAtual.cor2,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  'Após desconto de ${(taxaDesconto * 100).toStringAsFixed(1)}% de impostos',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: temaAtual.cor2,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'R\$ ${receitaLiquidaMensal.toStringAsFixed(2).replaceAll('.', ',')}',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: temaAtual.cor2,
                                  ),
                                ),
                                Text(
                                  '(desconto: R\$ ${descontoImpostoMensal.toStringAsFixed(2).replaceAll('.', ',')})',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: temaAtual.cor2,
                                  ),
                                ),
                              ],
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Receita Líquida Mensal',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: temaAtual.cor2,
                                      ),
                                    ),
                                    Text(
                                      'Após desconto de ${(taxaDesconto * 100).toStringAsFixed(1)}% de impostos',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: temaAtual.cor2,
                                      ),
                                    ),
                                  ],
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      'R\$ ${receitaLiquidaMensal.toStringAsFixed(2).replaceAll('.', ',')}',
                                      style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                        color: temaAtual.cor2,
                                      ),
                                    ),
                                    Text(
                                      '(desconto: R\$ ${descontoImpostoMensal.toStringAsFixed(2).replaceAll('.', ',')})',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: temaAtual.cor2,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                    ),
                    const SizedBox(height: 24),

                    const Text(
                      '🎯 Progresso das Metas',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    isMobile
                        ? Column(
                            children: [
                              _buildProgressCard(
                                'Meta Diária',
                                receitaHojeBruta,
                                metaDiaria,
                              ),
                              const SizedBox(height: 12),
                              _buildProgressCard(
                                'Meta Mensal',
                                receitaMesBruta,
                                metaMensal,
                              ),
                              const SizedBox(height: 16),
                              _buildMetaEditor(isMobile),
                              const SizedBox(height: 24),
                              // CARD de Registro de Plantões movido para cá no mobile
                              _buildRegistroPlantoesCard(isMobile),
                            ],
                          )
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 2,
                                child: Column(
                                  children: [
                                    _buildProgressCard(
                                      'Meta Diária',
                                      receitaHojeBruta,
                                      metaDiaria,
                                    ),
                                    const SizedBox(height: 12),
                                    _buildProgressCard(
                                      'Meta Mensal',
                                      receitaMesBruta,
                                      metaMensal,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                flex: 1,
                                child: _buildMetaEditor(isMobile),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                flex: 2,
                                child: _buildRegistroPlantoesCard(isMobile),
                              ),
                            ],
                          ),
                    const SizedBox(height: 24),
                    // LANÇAR ATENDIMENTOS
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '📋 Lançar Atendimentos',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.edit_outlined,
                            size: 18,
                            color: temaAtual.cor2,
                          ),
                          tooltip: 'Gerenciar Filas',
                          onPressed: () =>
                              _mostrarGerenciadorConvenios(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _convenios.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: isMobile ? 2 : 4,
                        crossAxisSpacing: isMobile ? 8 : 12,
                        mainAxisSpacing: isMobile ? 8 : 12,
                        // Ajusta a proporção do card. Um valor > 1 o torna mais largo.
                        childAspectRatio: 1.25,
                      ),
                      itemBuilder: (context, index) {
                        final convenio = _convenios[index];
                        return _buildConvenioCard(
                          convenio.nome,
                          '${totalPorFilaHoje(convenio.nome)}',
                          'R\$ ${convenio.valor.toStringAsFixed(2)}',
                          convenio.cor,
                          () =>
                              _registrarConsulta(convenio.nome, convenio.valor),
                          isMobile,
                        );
                      },
                    ),
                    const SizedBox(height: 24),

                    // ÚLTIMOS LANÇAMENTOS
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '⏱️ Últimos Lançamentos',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (_historicoConsultas.isNotEmpty)
                          TextButton.icon(
                            onPressed: _zerarHistorico,
                            icon: const Icon(
                              Icons.delete_sweep_outlined,
                              size: 18,
                            ),
                            label: const Text('Zerar'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: _historicoConsultas.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.all(16.0),
                              child: Text("Nenhuma consulta lançada."),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: _historicoConsultas.length > 5
                                  ? 5
                                  : _historicoConsultas.length,
                              itemBuilder: (context, index) {
                                final item = _historicoConsultas[index];
                                return ListTile(
                                  leading: const Icon(
                                    Icons.check_circle_outline,
                                    color: Colors.green,
                                    size: 20,
                                  ),
                                  title: Text(
                                    item.nomeConvenio,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  subtitle: Text(
                                    'R\$ ${item.valor.toStringAsFixed(2)}',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '${item.hora.hour.toString().padLeft(2, '0')}:${item.hora.minute.toString().padLeft(2, '0')}',
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          size: 18,
                                          color: Colors.red,
                                        ),
                                        onPressed: () =>
                                            _removerRegistro(index),
                                        tooltip: 'Remover registro',
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),

            // --- TAB 2: ANÁLISE ---
            SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(isMobile ? 12.0 : 16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // NOVO: Seletor de data para os gráficos diários
                    _buildAnaliseDatePicker(),
                    const SizedBox(height: 16),

                    // LAYOUT DOS GRÁFICOS (RESPONSIVO)
                    if (isMobile)
                      // Layout em Coluna para Celular (Faturamento abaixo da Pizza)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildPieChartSection(isMobile),
                          const SizedBox(height: 24),
                          _buildRevenueChartSection(isMobile),
                          const SizedBox(height: 24),
                          _buildHourlyChartSection(
                            isMobile,
                            horasComAtendimento,
                            consultasPorHora,
                            maxConsultasNaHora,
                          ),
                        ],
                      )
                    else
                      // Layout em Linha para Telas Maiores (Faturamento ao lado da Pizza)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 1,
                                child: _buildPieChartSection(isMobile),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                flex: 1,
                                child: _buildRevenueChartSection(isMobile),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          _buildHourlyChartSection(
                            isMobile,
                            horasComAtendimento,
                            consultasPorHora,
                            maxConsultasNaHora,
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- LÓGICA E WIDGETS PARA GRÁFICOS ---

  // NOVO: Contador para uma data específica
  int _getTotalConsultasParaData(DateTime data) {
    return _historicoConsultas.where((c) {
      return c.hora.day == data.day &&
          c.hora.month == data.month &&
          c.hora.year == data.year;
    }).length;
  }

  // NOVO: Horas ativas para uma data específica
  int _getHorasAtivasParaData(DateTime data) {
    final consultasDoDia = _historicoConsultas.where((c) {
      return c.hora.day == data.day &&
          c.hora.month == data.month &&
          c.hora.year == data.year;
    });
    final horasUnicas = consultasDoDia.map((c) => c.hora.hour).toSet();
    return horasUnicas.length;
  }

  // NOVO: Média por hora para uma data específica
  double _getMediaHoraParaData(DateTime data) {
    final horasAtivas = _getHorasAtivasParaData(data);
    if (horasAtivas == 0) return 0.0;
    return _getTotalConsultasParaData(data) / horasAtivas;
  }

  Future<void> _selecionarDataAnalise() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _analiseDataSelecionada,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      helpText: 'SELECIONAR DIA DA ANÁLISE',
      cancelText: 'CANCELAR',
      confirmText: 'OK',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: temaAtual.cor1, // header background color
              onPrimary: Colors.white, // header text color
              onSurface: temaAtual.cor2, // body text color
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: temaAtual.cor1, // button text color
              ),
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null && picked != _analiseDataSelecionada) {
      setState(() {
        _analiseDataSelecionada = picked;
      });
    }
  }

  Future<void> _selectDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(
        start: _revenueChartStartDate,
        end: _revenueChartEndDate,
      ),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)), // Permite hoje
    );

    if (picked != null) {
      setState(() {
        _revenueChartStartDate = picked.start;
        // Garante que a data final inclua o dia inteiro para comparação
        _revenueChartEndDate = DateTime(
          picked.end.year,
          picked.end.month,
          picked.end.day,
          23,
          59,
          59,
        );
      });
    }
  }

  Widget _buildAnaliseDatePicker() {
    final formattedDate =
        '${_analiseDataSelecionada.day.toString().padLeft(2, '0')}/${_analiseDataSelecionada.month.toString().padLeft(2, '0')}/${_analiseDataSelecionada.year}';
    final isHoje =
        _analiseDataSelecionada.day == DateTime.now().day &&
        _analiseDataSelecionada.month == DateTime.now().month &&
        _analiseDataSelecionada.year == DateTime.now().year;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'Dados de: ${isHoje ? 'Hoje' : formattedDate}',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        IconButton(
          icon: Icon(Icons.calendar_month_outlined, color: temaAtual.cor2),
          tooltip: 'Selecionar Outro Dia',
          onPressed: _selecionarDataAnalise,
        ),
      ],
    );
  }

  Map<DateTime, double> _getReceitaPorPeriodo(DateTime start, DateTime end) {
    final Map<DateTime, double> receitaPorDia = {};
    final normalizedStart = DateTime(start.year, start.month, start.day);
    final normalizedEnd = DateTime(end.year, end.month, end.day);

    // Cria um mapa de todos os dias no intervalo com receita 0.0
    final dayCount = normalizedEnd.difference(normalizedStart).inDays;
    for (int i = 0; i <= dayCount; i++) {
      final day = DateTime(
        normalizedStart.year,
        normalizedStart.month,
        normalizedStart.day + i,
      );
      receitaPorDia[day] = 0.0;
    }

    // Preenche com a receita real
    for (var consulta in _historicoConsultas) {
      final diaConsulta = DateTime(
        consulta.hora.year,
        consulta.hora.month,
        consulta.hora.day,
      );
      if (!diaConsulta.isBefore(normalizedStart) &&
          !diaConsulta.isAfter(normalizedEnd)) {
        if (receitaPorDia.containsKey(diaConsulta)) {
          receitaPorDia.update(diaConsulta, (value) => value + consulta.valor);
        }
      }
    }
    return receitaPorDia;
  }

  Widget _buildRevenueChartWidget() {
    final dadosReceita = _getReceitaPorPeriodo(
      _revenueChartStartDate,
      _revenueChartEndDate,
    );
    final sortedEntries = dadosReceita.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    final List<FlSpot> spots = [];
    for (int i = 0; i < sortedEntries.length; i++) {
      spots.add(FlSpot(i.toDouble(), sortedEntries[i].value));
    }

    if (spots.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: Text(
          'Nenhum atendimento no período selecionado.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return AspectRatio(
      aspectRatio: 1.7,
      child: LineChart(
        LineChartData(
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (touchedSpot) => temaAtual.cor2,
              getTooltipItems: (List<LineBarSpot> touchedSpots) {
                return touchedSpots.map((barSpot) {
                  final flSpot = barSpot;
                  if (flSpot.x == -1 || flSpot.y == -1) {
                    return null;
                  }
                  return LineTooltipItem(
                    'R\$ ${flSpot.y.toStringAsFixed(2)}\n',
                    const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  );
                }).toList();
              },
            ),
          ),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: true,
            getDrawingHorizontalLine: (value) =>
                FlLine(color: Colors.grey.shade200, strokeWidth: 1),
            getDrawingVerticalLine: (value) =>
                FlLine(color: Colors.grey.shade200, strokeWidth: 1),
          ),
          titlesData: FlTitlesData(
            leftTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 30,
                interval: 1,
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  if (index < 0 || index >= sortedEntries.length) {
                    return const SizedBox.shrink();
                  }

                  // Intervalo dinâmico para evitar sobreposição de legendas
                  const int labelCount = 7;
                  final int totalDays = sortedEntries.length;
                  final int interval = (totalDays > labelCount)
                      ? (totalDays / labelCount).ceil()
                      : 1;

                  if (index % interval != 0 && index != totalDays - 1) {
                    return const SizedBox.shrink();
                  }

                  final dia = sortedEntries[index].key;
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    child: Text(
                      '${dia.day}/${dia.month}',
                      style: const TextStyle(fontSize: 10),
                    ),
                  );
                },
              ),
            ),
          ),
          borderData: FlBorderData(
            show: true,
            border: Border.all(color: Colors.grey.shade300),
          ),
          minX: 0,
          maxX: (sortedEntries.length - 1).toDouble(),
          minY: 0,
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: temaAtual.cor1,
              barWidth: 4,
              isStrokeCapRound: true,
              dotData: const FlDotData(show: true),
              belowBarData: BarAreaData(
                show: true,
                color: temaAtual.cor1.withOpacity(0.2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRevenueChartSection(bool isMobile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              '💰 Faturamento por Período',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            IconButton(
              icon: Icon(
                Icons.calendar_today_outlined,
                size: 18,
                color: temaAtual.cor2,
              ),
              tooltip: 'Selecionar Período',
              onPressed: _selectDateRange,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: EdgeInsets.all(isMobile ? 12 : 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: _buildRevenueChartWidget(),
        ),
      ],
    );
  }

  void _mostrarGerenciadorConvenios(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (ctx, modalSetState) {
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.75,
            builder: (_, scrollController) => Container(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Text(
                    'Gerenciar Filas',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      itemCount: _convenios.length,
                      itemBuilder: (context, index) {
                        final convenio = _convenios[index];
                        return Card(
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: convenio.cor,
                              radius: 15,
                            ),
                            title: Text(convenio.nome),
                            subtitle: Text(
                              'R\$ ${convenio.valor.toStringAsFixed(2)}',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    color: Colors.blue,
                                  ),
                                  onPressed: () {
                                    _editarConvenio(context, index, (
                                      updatedConvenio,
                                    ) {
                                      modalSetState(() {
                                        _convenios[index] = updatedConvenio;
                                      });
                                      setState(
                                        () {},
                                      ); // Atualiza a tela principal
                                      _salvarDados();
                                    });
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    color: Colors.red,
                                  ),
                                  onPressed: () {
                                    modalSetState(() {
                                      _convenios.removeAt(index);
                                    });
                                    setState(
                                      () {},
                                    ); // Atualiza a tela principal
                                    _salvarDados();
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.add_circle_outline),
                      label: const Text('Adicionar Nova Fila'),
                      onPressed: () {
                        _editarConvenio(context, null, (newConvenio) {
                          modalSetState(() {
                            _convenios.add(newConvenio);
                          });
                          setState(() {}); // Atualiza a tela principal
                          _salvarDados();
                        });
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _editarConvenio(
    BuildContext context,
    int? index,
    Function(Convenio) onSave,
  ) {
    final isCreating = index == null;
    // Usa variáveis temporárias para evitar modificar o objeto original até salvar
    String tempNome = isCreating ? '' : _convenios[index!].nome;
    double tempValor = isCreating ? 0.0 : _convenios[index!].valor;
    Color tempCor = isCreating ? Colors.blue : _convenios[index!].cor;
    final id = isCreating ? UniqueKey().toString() : _convenios[index!].id;

    final nomeController = TextEditingController(text: tempNome);
    final valorController = TextEditingController(
      text: tempValor > 0 ? tempValor.toStringAsFixed(2) : '',
    );

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: Text(isCreating ? 'Adicionar Fila' : 'Editar Fila'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nomeController,
                      decoration: const InputDecoration(
                        labelText: 'Nome da Fila',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: valorController,
                      decoration: const InputDecoration(
                        labelText: 'Valor (R\$)',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Cor da Fila:'),
                        GestureDetector(
                          onTap: () {
                            Color pickerColor = tempCor;
                            showDialog(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('Escolha uma cor'),
                                content: SingleChildScrollView(
                                  child: ColorPicker(
                                    pickerColor: pickerColor,
                                    onColorChanged: (color) =>
                                        pickerColor = color,
                                  ),
                                ),
                                actions: <Widget>[
                                  ElevatedButton(
                                    child: const Text('Selecionar'),
                                    onPressed: () {
                                      setStateDialog(
                                        () => tempCor = pickerColor,
                                      );
                                      Navigator.of(context).pop();
                                    },
                                  ),
                                ],
                              ),
                            );
                          },
                          child: CircleAvatar(
                            backgroundColor: tempCor,
                            radius: 18,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancelar'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final finalNome = nomeController.text;
                    final finalValor =
                        double.tryParse(
                          valorController.text.replaceAll(',', '.'),
                        ) ??
                        0.0;

                    if (finalNome.isEmpty) return;

                    final newConvenio = Convenio(
                      id: id,
                      nome: finalNome,
                      valor: finalValor,
                      cor: tempCor,
                    );
                    onSave(newConvenio);
                    Navigator.pop(context);
                  },
                  child: const Text('Salvar'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _mostrarSeletorTema(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Escolher Tema',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: temaAtual.cor2,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: temasPredefinidos.entries.map((entry) {
                  final tema = entry.value;
                  final isSelected = entry.key == _temaSelecionado;
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _temaSelecionado = entry.key;
                      });
                      _salvarDados();
                      Navigator.pop(context);
                    },
                    child: Container(
                      width: 140,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: tema.fundoBatida,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected ? tema.cor1 : Colors.grey.shade300,
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            height: 40,
                            decoration: BoxDecoration(
                              color: tema.cor1,
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            tema.nome,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: tema.cor2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${tema.cor1.value.toRadixString(16).toUpperCase()}',
                            style: TextStyle(fontSize: 11, color: tema.cor2),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Fechar'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _mostrarMenuBackup(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => DefaultTabController(
          length: 3,
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.8,
            minChildSize: 0.5,
            maxChildSize: 0.9,
            builder: (context, scrollController) => Column(
              children: [
                // Barra de arrastar
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12.0),
                  child: Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),

                // Título
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Text(
                    'Sincronização e Backup',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: temaAtual.cor2,
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Abas
                TabBar(
                  labelColor: temaAtual.cor1,
                  unselectedLabelColor: Colors.grey,
                  indicatorColor: temaAtual.cor1,
                  tabs: const [
                    Tab(icon: Icon(Icons.dns_outlined), text: 'Servidor'),
                    Tab(icon: Icon(Icons.sync_alt), text: 'Sincronizar'),
                    Tab(icon: Icon(Icons.backup_outlined), text: 'Backup'),
                  ],
                ),

                // Conteúdo das Abas
                Expanded(
                  child: TabBarView(
                    children: [
                      // --- ABA 1: SERVIDOR ---
                      _buildTabServidor(scrollController, setState),

                      // --- ABA 2: SINCRONIZAR ---
                      _buildTabSincronizar(scrollController, setState),

                      // --- ABA 3: BACKUP ---
                      _buildTabBackup(scrollController),
                    ],
                  ),
                ),

                // Botão Fechar
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Fechar'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- WIDGETS DAS ABAS DE SINCRONIZAÇÃO ---

  Widget _buildTabServidor(
    ScrollController scrollController,
    void Function(void Function()) setState,
  ) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    return SingleChildScrollView(
      controller: scrollController,
      padding: EdgeInsets.all(isMobile ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          // Status do Servidor
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _server == null
                  ? const Color(0xFFFEF3C7)
                  : const Color(0xFFDCFCE7),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _server == null
                    ? const Color(0xFFFCD34D)
                    : const Color(0xFF86EFAC),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _server == null
                      ? Icons.cloud_off_outlined
                      : Icons.cloud_sync_outlined,
                  color: _server == null
                      ? Colors.orange.shade700
                      : Colors.green.shade700,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _server == null
                            ? 'Sincronização Inativa'
                            : 'Sincronização Ativa ✓',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: _server == null
                              ? Colors.orange.shade700
                              : Colors.green.shade700,
                        ),
                      ),
                      Text(
                        'Seu IP: $meuIpLocal:$_syncPort',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Botão Ativar/Desativar Servidor
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () async {
                if (_server == null) {
                  await _iniciarServidorSincronizacao(modalSetState: setState);
                } else {
                  await _pararServidorSincronizacao();
                }
                // Atualiza a UI da modal
                setState(() {});
              },
              icon: Icon(
                _server == null
                    ? Icons.power_settings_new_outlined
                    : Icons.stop_circle_outlined,
              ),
              label: Text(
                _server == null
                    ? 'Ativar Sincronização'
                    : 'Desativar Sincronização',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _server == null ? temaAtual.cor1 : Colors.red,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Configuração da Porta',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          _buildPortEditor(),
        ],
      ),
    );
  }

  Widget _buildTabSincronizar(
    ScrollController scrollController,
    void Function(void Function()) setState,
  ) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    return SingleChildScrollView(
      controller: scrollController,
      padding: EdgeInsets.all(isMobile ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          // Seção de Sincronização Bidirecional
          const Text(
            'Sincronizar com Outro Dispositivo',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Insira o IP de outro aparelho na mesma rede WiFi para sincronizar dados.',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ipDestinoController,
            decoration: InputDecoration(
              labelText: 'IP do Outro Aparelho',
              hintText: '192.168.1.50',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              prefixIcon: const Icon(Icons.devices_outlined),
            ),
          ),

          const SizedBox(height: 12),

          // Botões de Sincronização
          SizedBox(
            width: double.infinity,
            child: PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'push' || value == 'pull') {
                  _sincronizarComDispositivo(value, modalSetState: setState);
                }
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(
                  value: 'push',
                  child: ListTile(
                    leading: Icon(Icons.upload_outlined),
                    title: Text('Enviar Dados'),
                    subtitle: Text('Sobrescreve os dados do outro aparelho'),
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'pull',
                  child: ListTile(
                    leading: Icon(Icons.download_outlined),
                    title: Text('Receber Dados'),
                    subtitle: Text('Sobrescreve os dados deste aparelho'),
                  ),
                ),
              ],
              child: ElevatedButton.icon(
                onPressed: null, // O PopupMenuButton cuida do clique
                icon: const Icon(Icons.sync_alt),
                label: const Text('Sincronizar...'),
                style: ElevatedButton.styleFrom(
                  disabledBackgroundColor: temaAtual.cor1.withOpacity(0.8),
                  disabledForegroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Seção de Descoberta de Rede
          const Text(
            'Dispositivos na Rede',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _discoverServices(modalSetState: setState),
              icon: _isDiscovering
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search),
              label: Text(
                _isDiscovering ? 'Parar Busca' : 'Buscar Dispositivos',
              ),
            ),
          ),
          if (_isDiscovering && _discoveredServices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Center(
                child: Text(
                  'Buscando... Nenhum dispositivo encontrado ainda.',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            )
          else if (_discoveredServices.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 8),
              constraints: const BoxConstraints(maxHeight: 150),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _discoveredServices.length,
                itemBuilder: (context, index) {
                  final service = _discoveredServices[index];
                  return ListTile(
                    leading: const Icon(Icons.devices_other_outlined),
                    title: Text(service.name ?? 'Dispositivo'),
                    subtitle: Text('${service.host}:${service.port}'),
                    onTap: () {
                      _ipDestinoController.text = service.host ?? '';
                      _syncPortController.text = (service.port ?? _syncPort)
                          .toString();
                      setState(() {
                        _syncPort = service.port ?? _syncPort;
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          backgroundColor: Colors.blue,
                          content: Text('IP e Porta preenchidos!'),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          const SizedBox(height: 24),

          // Seção de Sincronização Automática
          const Text(
            'Sincronização Automática',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: SwitchListTile(
              title: const Text(
                'Ativar Sync Automático',
                style: TextStyle(fontSize: 14),
              ),
              subtitle: Text(
                _parceiroSyncIp == null
                    ? 'Sincronize manualmente uma vez para definir um parceiro.'
                    : 'Sincronizando com: $_parceiroSyncIp',
                style: const TextStyle(fontSize: 11),
              ),
              value: _syncAutomaticoAtivo,
              onChanged: (bool value) {
                setState(() {
                  _syncAutomaticoAtivo = value;
                });
                _salvarDados();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBackup(ScrollController scrollController) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    return SingleChildScrollView(
      controller: scrollController,
      padding: EdgeInsets.all(isMobile ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          // Seção de Importação/Exportação
          const Text(
            'Importar/Exportar Arquivo',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),

          // Botão Exportar
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _exportarParaArquivoJson,
              icon: const Icon(Icons.download_outlined),
              label: const Text('Exportar Dados (JSON)'),
              style: ElevatedButton.styleFrom(
                backgroundColor: temaAtual.cor2,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _importarDeArquivoJson,
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('Importar de Arquivo (.json)'),
              style: ElevatedButton.styleFrom(
                backgroundColor: temaAtual.cor2,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Info de Importação
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: temaAtual.fundoBatida,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: temaAtual.cor1.withOpacity(0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ℹ️ Como Importar',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: temaAtual.cor2,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Para restaurar um backup, use a opção "Importar de Arquivo (.json)" e selecione o arquivo de backup que você salvou anteriormente.',
                  style: TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Info Geral
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Dados Atuais no Dispositivo',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Text(
                  '📊 Consultas: ${_historicoConsultas.length}\n'
                  '💰 Receita: R\$ ${receitaHojeBruta.toStringAsFixed(2)}\n'
                  '🎯 Meta Diária: R\$ ${metaDiaria.toStringAsFixed(2)}\n'
                  '📅 Meta Mensal: R\$ ${metaMensal.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- COMPONENTES AUXILIARES DE WIDGETS ---
  Widget _buildMetricCard(
    String t,
    String v,
    String s,
    IconData i,
    bool isMobile,
  ) {
    return Container(
      padding: EdgeInsets.all(isMobile ? 10 : 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                t,
                style: TextStyle(
                  fontSize: isMobile ? 10 : 11,
                  color: Colors.grey,
                ),
              ),
              Icon(i, size: 16, color: Colors.grey),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            v,
            style: TextStyle(
              fontSize: isMobile ? 16 : 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            s,
            style: TextStyle(fontSize: isMobile ? 9 : 10, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressCard(String titulo, double real, double meta) {
    double porcentagem = (meta > 0) ? (real / meta) : 0.0;
    if (porcentagem > 1.0) porcentagem = 1.0;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            titulo,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: temaAtual.cor2,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Real:', style: TextStyle(fontSize: 11)),
              Text(
                'R\$ ${real.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: porcentagem,
            backgroundColor: Colors.grey.shade100,
            color: temaAtual.cor1,
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Meta:', style: TextStyle(fontSize: 11)),
              Text(
                'R\$ ${meta.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetaEditor(bool isMobile) {
    return Container(
      padding: EdgeInsets.all(isMobile ? 12 : 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '⚙️ Configurar Valores das Metas',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _metaDiariaController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Meta Diária (R\$)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _metaMensalController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Meta Mensal (R\$)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _taxaDescontoController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Taxa de Imposto (%)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: temaAtual.cor1),
              onPressed: () {
                setState(() {
                  metaDiaria =
                      double.tryParse(_metaDiariaController.text) ?? 0.0;
                  taxaDesconto =
                      (double.tryParse(_taxaDescontoController.text) ?? 0.0) /
                      100;
                  metaMensal =
                      double.tryParse(_metaMensalController.text) ?? 0.0;
                });
                _salvarDados();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('✅ Metas salvas com sucesso!'),
                    backgroundColor: temaAtual.cor1,
                  ),
                );
              },
              child: const Text(
                'Salvar Metas',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPortEditor() {
    return TextField(
      controller: _syncPortController,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: 'Porta',
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: const Icon(Icons.save_outlined, size: 20),
          tooltip: 'Salvar Porta',
          onPressed: () {
            final novaPorta = int.tryParse(_syncPortController.text);
            if (novaPorta != null && novaPorta > 1024) {
              setState(() {
                _syncPort = novaPorta;
              });
              _salvarDados();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  backgroundColor: Colors.green,
                  content: Text('✅ Porta de sincronização salva!'),
                ),
              );
            }
          },
        ),
      ),
    );
  }

  Widget _buildPieChartSection(bool isMobile) {
    final isHoje =
        _analiseDataSelecionada.day == DateTime.now().day &&
        _analiseDataSelecionada.month == DateTime.now().month &&
        _analiseDataSelecionada.year == DateTime.now().year;
    final titulo = isHoje
        ? 'Faturamento por Fila (Hoje)'
        : 'Faturamento por Fila';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '📊 $titulo',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        Container(
          padding: EdgeInsets.all(isMobile ? 12 : 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: _buildPieChart(isMobile, _analiseDataSelecionada),
        ),
      ],
    );
  }

  Widget _buildHourlyChartSection(
    bool isMobile,
    List<int> horasComAtendimento,
    Map<int, List<ConsultaRegistro>> consultasPorHora,
    int maxConsultasNaHora,
  ) {
    final isHoje =
        _analiseDataSelecionada.day == DateTime.now().day &&
        _analiseDataSelecionada.month == DateTime.now().month &&
        _analiseDataSelecionada.year == DateTime.now().year;
    final titulo = isHoje
        ? 'Distribuição Horária (Hoje)'
        : 'Distribuição Horária';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '🕒 $titulo',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        Container(
          padding: EdgeInsets.all(isMobile ? 12 : 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Column(
            children: [
              if (horasComAtendimento.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    'Nenhum atendimento registrado para exibir o gráfico.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              else
                for (int hora in horasComAtendimento)
                  _buildDynamicChartRow(
                    '$hora:00',
                    consultasPorHora[hora]!.length, // Usando o dado já agrupado
                    maxConsultasNaHora,
                    _analiseDataSelecionada,
                  ),
              const SizedBox(height: 8),
              const Divider(),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Text(
                    'Total: ${_getTotalConsultasParaData(_analiseDataSelecionada)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'Horas: ${_getHorasAtivasParaData(_analiseDataSelecionada)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'Média: ${_getMediaHoraParaData(_analiseDataSelecionada).toStringAsFixed(1)}/h',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: temaAtual.cor1,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildConvenioCard(
    String nome,
    String total,
    String valorUnitario,
    Color cor,
    VoidCallback onAction,
    bool isMobile,
  ) {
    return Container(
      padding: EdgeInsets.all(isMobile ? 10 : 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: cor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      nome,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: isMobile ? 12 : 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '$total hoje',
                style: TextStyle(
                  fontSize: isMobile ? 11 : 12,
                  color: Colors.grey,
                ),
              ),
              Text(
                '$valorUnitario / consulta',
                style: TextStyle(
                  fontSize: isMobile ? 10 : 11,
                  color: Colors.blueGrey,
                ),
              ),
            ],
          ),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onAction,
              style: ElevatedButton.styleFrom(
                backgroundColor: temaAtual.cor1,
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(vertical: isMobile ? 8 : 10),
              ),
              child: Text(
                '+ Registro',
                style: TextStyle(fontSize: isMobile ? 10 : 11),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDynamicChartRow(
    String hora,
    int quantidade,
    int maxConsultas,
    DateTime data,
  ) {
    final double fatorLargura = maxConsultas > 0
        ? (quantidade / maxConsultas)
        : 0.0;
    final String detalhes = detalhesPorFaixaHoraria(
      int.parse(hora.split(':')[0]),
      data,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 45,
                child: Text(
                  hora,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Expanded(
                child: Container(
                  height: 20,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: fatorLargura,
                    child: Container(
                      decoration: BoxDecoration(
                        color: temaAtual.cor1,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text(
                  '$quantidade',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: temaAtual.cor2,
                  ),
                ),
              ),
            ],
          ),
          if (quantidade > 0)
            Padding(
              padding: const EdgeInsets.only(left: 45, top: 4),
              child: Text(
                detalhes,
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPieChart(bool isMobile, DateTime data) {
    final consultasDoDia = _historicoConsultas.where(
      (c) =>
          c.hora.day == data.day &&
          c.hora.month == data.month &&
          c.hora.year == data.year,
    );

    final double faturamentoTotal = consultasDoDia.fold(
      0.0,
      (soma, item) => soma + item.valor,
    );

    if (faturamentoTotal == 0) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: Text(
          'Nenhum faturamento no dia selecionado para exibir o gráfico.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    // Calcula o faturamento por fila em vez da contagem
    final Map<String, double> faturamentoPorFila = {};
    for (var consulta in consultasDoDia) {
      faturamentoPorFila.update(
        consulta.nomeConvenio,
        (value) => value + consulta.valor,
        ifAbsent: () => consulta.valor,
      );
    }

    final List<PieChartSectionData> sections = [];
    int sectionIndex = 0;
    for (var convenio in _convenios) {
      final faturamento = faturamentoPorFila[convenio.nome] ?? 0.0;
      if (faturamento > 0) {
        final isTouched = sectionIndex == _touchedIndex;

        sections.add(
          PieChartSectionData(
            color: convenio.cor,
            value: faturamento,
            title: isTouched
                // Mostra o valor em R$ ao tocar
                ? 'R\$${faturamento.toStringAsFixed(0)}'
                // Mostra a porcentagem do faturamento
                : '${(faturamento / faturamentoTotal * 100).toStringAsFixed(0)}%',
            radius: isTouched ? 60.0 : 50.0,
            titleStyle: TextStyle(
              fontSize: isTouched ? 14 : 12,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        );
        sectionIndex++;
      }
    }

    return Row(
      children: <Widget>[
        Expanded(
          child: AspectRatio(
            aspectRatio: 1,
            child: PieChart(
              PieChartData(
                pieTouchData: PieTouchData(
                  touchCallback: (FlTouchEvent event, pieTouchResponse) {
                    // Defer the setState call to prevent exceptions when the callback
                    // is triggered during a build phase (e.g., by a hover event).
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      setState(() {
                        if (!event.isInterestedForInteractions ||
                            pieTouchResponse == null ||
                            pieTouchResponse.touchedSection == null) {
                          _touchedIndex = -1;
                          return;
                        }
                        _touchedIndex = pieTouchResponse
                            .touchedSection!
                            .touchedSectionIndex;
                      });
                    });
                  },
                ),
                borderData: FlBorderData(show: false),
                sectionsSpace: 2,
                centerSpaceRadius: 40,
                sections: sections,
              ),
            ),
          ),
        ),
        SizedBox(width: isMobile ? 12 : 20),
        Column(
          mainAxisSize: MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _convenios.map((convenio) {
            final faturamento = faturamentoPorFila[convenio.nome] ?? 0.0;
            return Padding(
              padding: const EdgeInsets.only(bottom: 4.0),
              child: _buildIndicator(
                color: convenio.cor,
                text:
                    '${convenio.nome} (R\$ ${faturamento.toStringAsFixed(2)})',
                isSquare: true,
                isMobile: isMobile,
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildIndicator({
    required Color color,
    required String text,
    bool isSquare = false,
    double size = 12,
    bool isMobile = false,
  }) => Row(
    children: <Widget>[
      Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: isSquare ? BoxShape.rectangle : BoxShape.circle,
          color: color,
        ),
      ),
      const SizedBox(width: 8),
      Text(text, style: TextStyle(fontSize: isMobile ? 11 : 12)),
    ],
  );
}
