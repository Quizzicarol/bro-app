import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/relay_service.dart';

class RelayManagementScreen extends StatefulWidget {
  const RelayManagementScreen({Key? key}) : super(key: key);

  @override
  State<RelayManagementScreen> createState() => _RelayManagementScreenState();
}

class _RelayManagementScreenState extends State<RelayManagementScreen> {
  final _relayService = RelayService();
  final _newRelayController = TextEditingController();
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRelays();
  }

  @override
  void dispose() {
    _newRelayController.dispose();
    super.dispose();
  }

  Future<void> _loadRelays() async {
    await _relayService.initialize();
    setState(() => _isLoading = false);
  }

  Future<void> _addRelay() async {
    final url = _newRelayController.text.trim();
    
    if (url.isEmpty) return;
    
    if (!url.startsWith('wss://') && !url.startsWith('ws://')) {
      _showError('URL deve começar com wss:// ou ws://');
      return;
    }
    
    setState(() => _isLoading = true);
    
    try {
      await _relayService.addRelay(url);
      _newRelayController.clear();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Relay $url adicionado'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      _showError('Erro ao adicionar relay: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _removeRelay(String url) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remover Relay', style: TextStyle(color: Colors.white)),
        content: Text(
          'Deseja remover o relay $url?',
          style: const TextStyle(color: Color(0xB3FFFFFF)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Remover', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    
    if (confirm == true) {
      await _relayService.removeRelay(url);
      setState(() {});
    }
  }

  Future<void> _testRelay(String url) async {
    setState(() => _isLoading = true);
    
    final success = await _relayService.connectToRelay(url);
    
    setState(() => _isLoading = false);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '✅ Relay conectado!' : '❌ Falha na conexão'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _addPredefinedRelay(String url) {
    _newRelayController.text = url;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xF70A0A0A),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Gerenciar Relays',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0x33FF6B35), height: 1),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFFF6B35)))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Info card
                  _buildInfoCard(),
                  const SizedBox(height: 24),
                  
                  // Adicionar novo relay
                  _buildAddRelaySection(),
                  const SizedBox(height: 24),
                  
                  // Relays populares
                  _buildPopularRelaysSection(),
                  const SizedBox(height: 24),
                  
                  // Relays ativos
                  _buildActiveRelaysSection(),
                ],
              ),
            ),
    );
  }

  Widget _buildInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF9C27B0).withOpacity(0.2),
            const Color(0xFF9C27B0).withOpacity(0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x339C27B0)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF9C27B0).withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.info_outline, color: Color(0xFF9C27B0)),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'O que são Relays?',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Relays são servidores que transmitem eventos Nostr. '
                  'Use múltiplos relays para maior resiliência e privacidade.',
                  style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddRelaySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Adicionar Relay',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _newRelayController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'wss://relay.example.com',
                  hintStyle: const TextStyle(color: Color(0x66FFFFFF)),
                  prefixIcon: const Icon(Icons.link, color: Color(0xFFFF6B35)),
                  filled: true,
                  fillColor: const Color(0x0DFFFFFF),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0x33FFFFFF)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFFF6B35)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton(
              onPressed: _addRelay,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF6B35),
                padding: const EdgeInsets.all(16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Icon(Icons.add, color: Colors.white),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPopularRelaysSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Relays Populares',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: RelayService.defaultRelays.map((url) {
            final isActive = _relayService.activeRelays.contains(url);
            return GestureDetector(
              onTap: isActive ? null : () => _addPredefinedRelay(url),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isActive 
                      ? const Color(0x1AFF6B35)
                      : const Color(0x0DFFFFFF),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isActive 
                        ? const Color(0xFFFF6B35)
                        : const Color(0x33FFFFFF),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isActive)
                      const Icon(Icons.check, color: Color(0xFFFF6B35), size: 16),
                    if (isActive) const SizedBox(width: 4),
                    Text(
                      url.replaceAll('wss://', ''),
                      style: TextStyle(
                        color: isActive ? const Color(0xFFFF6B35) : const Color(0xB3FFFFFF),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 16),
        const Text(
          'Relays Pagos (mais privacidade)',
          style: TextStyle(
            color: Color(0xB3FFFFFF),
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: RelayService.paidRelays.map((url) {
            return GestureDetector(
              onTap: () => _addPredefinedRelay(url),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0x1A9C27B0),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0x339C27B0)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.star, color: Color(0xFF9C27B0), size: 14),
                    const SizedBox(width: 4),
                    Text(
                      url.replaceAll('wss://', ''),
                      style: const TextStyle(color: Color(0xFFBA68C8), fontSize: 12),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildActiveRelaysSection() {
    final activeRelays = _relayService.activeRelays;
    final relayStatus = _relayService.relayStatus;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Relays Ativos',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0x1AFF6B35),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${activeRelays.length} conectados',
                style: const TextStyle(
                  color: Color(0xFFFF6B35),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (activeRelays.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0x0DFFFFFF),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0x33FFFFFF)),
            ),
            child: const Center(
              child: Column(
                children: [
                  Icon(Icons.cloud_off, color: Color(0x66FFFFFF), size: 48),
                  SizedBox(height: 12),
                  Text(
                    'Nenhum relay conectado',
                    style: TextStyle(color: Color(0x99FFFFFF)),
                  ),
                ],
              ),
            ),
          )
        else
          ...activeRelays.map((url) {
            final isConnected = relayStatus[url] ?? false;
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0x0DFFFFFF),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isConnected 
                      ? const Color(0x3300FF00)
                      : const Color(0x33FF0000),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: isConnected ? Colors.green : Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          url,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isConnected ? 'Conectado' : 'Desconectado',
                          style: TextStyle(
                            color: isConnected 
                                ? Colors.green.withOpacity(0.8)
                                : Colors.red.withOpacity(0.8),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh, color: Color(0xFFFF6B35)),
                    onPressed: () => _testRelay(url),
                    tooltip: 'Reconectar',
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () => _removeRelay(url),
                    tooltip: 'Remover',
                  ),
                ],
              ),
            );
          }).toList(),
      ],
    );
  }
}
