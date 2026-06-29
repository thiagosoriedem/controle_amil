import 'package:flutter/material.dart';

// Modelo para os tipos de fila/convênio
class Convenio {
  String id;
  String nome;
  double valor;
  Color cor;

  Convenio({
    required this.id,
    required this.nome,
    required this.valor,
    required this.cor,
  });

  // Métodos para serialização JSON (para salvar localmente)
  Map<String, dynamic> toJson() => {
    'id': id,
    'nome': nome,
    'valor': valor,
    'cor': cor.value,
  };

  factory Convenio.fromJson(Map<String, dynamic> json) => Convenio(
    id: json['id'] ?? UniqueKey().toString(),
    nome: json['nome'],
    valor: json['valor'],
    cor: Color(json['cor']),
  );
}
