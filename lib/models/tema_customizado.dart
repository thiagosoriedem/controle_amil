import 'package:flutter/material.dart';

// --- TEMAS PREDEFINIDOS ---
class TemaCustomizado {
  final String nome;
  final Color cor1; // Primária
  final Color cor2; // Secundária
  final Color fundoBatida;

  const TemaCustomizado({
    required this.nome,
    required this.cor1,
    required this.cor2,
    required this.fundoBatida,
  });
}

final temasPredefinidos = {
  'azul': const TemaCustomizado(
    nome: 'Azul',
    cor1: Color(0xFF2563EB),
    cor2: Color(0xFF1E3A8A),
    fundoBatida: Color(0xFFF8FAFC),
  ),
  'rosa': const TemaCustomizado(
    nome: 'Rosa',
    cor1: Color(0xFFEC4899),
    cor2: Color(0xFFBE185D),
    fundoBatida: Color(0xFFFCE7F3),
  ),
  'roxo': const TemaCustomizado(
    nome: 'Roxo',
    cor1: Color(0xFFA855F7),
    cor2: Color(0xFF7E22CE),
    fundoBatida: Color(0xFFFAF5FF),
  ),
  'verde': const TemaCustomizado(
    nome: 'Verde',
    cor1: Color(0xFF10B981),
    cor2: Color(0xFF047857),
    fundoBatida: Color(0xFFF0FDF4),
  ),
  'laranja': const TemaCustomizado(
    nome: 'Laranja',
    cor1: Color(0xFFF97316),
    cor2: Color(0xFFB45309),
    fundoBatida: Color(0xFFFFF7ED),
  ),
};
