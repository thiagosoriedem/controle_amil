// Modelo para estruturar os registros de plantões
class PlantaoRegistro {
  final String id;
  final bool chamei5Pacientes;
  final int pacientesAdicionais;
  final double valorTotal;
  final DateTime hora;
  final DateTime modificadoEm;

  PlantaoRegistro({
    required this.id,
    required this.chamei5Pacientes,
    required this.pacientesAdicionais,
    required this.valorTotal,
    required this.hora,
    required this.modificadoEm,
  });
}