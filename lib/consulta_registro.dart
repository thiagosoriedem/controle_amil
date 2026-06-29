// Modelo para estruturar os registros de consultas
class ConsultaRegistro {
  final String id; // Identificador único para cada registro
  final String nomeConvenio;
  final double valor;
  final DateTime hora;
  final DateTime modificadoEm; // Para LWW (Last Write Wins)

  ConsultaRegistro({
    // Adiciona 'id' ao construtor
    required this.id,
    required this.nomeConvenio,
    required this.valor,
    required this.hora,
    required this.modificadoEm,
  });
}