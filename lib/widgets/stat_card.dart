 import 'package:flutter/material.dart';

/// Card de estatística replicando o design do dashboard web
/// Cores: --primary-orange: #FF6B35, fundo rgba(255, 255, 255, 0.05)
class StatCard extends StatelessWidget {
  final String emoji;
  final String value;
  final String label;
  final VoidCallback? onTap;

  const StatCard({
    Key? key,
    required this.emoji,
    required this.value,
    required this.label,
    this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0D0D0D), // rgba(255, 255, 255, 0.05) em fundo preto
          border: Border.all(
            color: const Color(0x33FF6B35), // rgba(255, 107, 53, 0.2)
            width: 1,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Emoji Icon
                  Text(
                    emoji,
                    style: const TextStyle(fontSize: 28),
                  ),
                  const SizedBox(height: 6),
                  
                  // Value
                  Flexible(
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 20),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          value,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  
                  // Label
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xCCFFFFFF), // rgba(255, 255, 255, 0.8)
                      fontWeight: FontWeight.w400,
                      height: 1.2,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
