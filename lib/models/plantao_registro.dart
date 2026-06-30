// Modelo para estruturar os registros de plantões
class PlantaoRegistro {
  final String id;
  final int bonusHoras; // Quantos bônus de hora foram reinvindicados
  final int pacientesAdicionais;
  final int duracaoSegundos; // Duração total do plantão
  final double valorTotal;
  final DateTime hora; // Hora de início do plantão
  final DateTime modificadoEm;

  PlantaoRegistro({
    required this.id,
    required this.bonusHoras,
    required this.pacientesAdicionais,
    required this.duracaoSegundos,
    required this.valorTotal,
    required this.hora,
    required this.modificadoEm,
  });
}