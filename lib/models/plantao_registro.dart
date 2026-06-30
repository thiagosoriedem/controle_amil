// Modelo para estruturar os registros de plantões
class PlantaoRegistro {
  final String id;
  final bool bonusAplicado; // Se o bônus por 5+ pacientes/hora foi aplicado
  final int bonusHoras;
  final int pacientesAdicionais;
  final int duracaoSegundos;
  final double valorTotal;
  final DateTime hora; // Hora do registro
  final DateTime modificadoEm;

  PlantaoRegistro({
    required this.id,
    required this.bonusAplicado,
    required this.bonusHoras,
    required this.pacientesAdicionais,
    required this.duracaoSegundos,
    required this.valorTotal,
    required this.hora,
    required this.modificadoEm,
  });
}