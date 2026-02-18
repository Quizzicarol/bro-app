import 'package:flutter/material.dart';

/// Card de estatística replicando o design do dashboard web
/// Cores: --primary-orange: #FF6B35, fundo rgba(255, 255, 255, 0.05)
class StatCard extends StatelessWidget {
  final String? emoji;
  final Widget? iconWidget;
  final String value;
  final String label;
  final VoidCallback? onTap;

  const StatCard({
    Key? key,
    this.emoji,
    this.iconWidget,
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
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Icon - emoji or widget
                  if (iconWidget != null)
                    iconWidget!
                  else if (emoji != null)
                    Text(
                      emoji!,
                      style: const TextStyle(fontSize: 20),
                    ),
                  const SizedBox(height: 3),

                  // Value
                  Flexible(
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 16),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          value,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),

                  // Label
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 9,
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
