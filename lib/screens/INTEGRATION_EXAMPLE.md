# Exemplo de Integração - DepositScreen

## 1. Adicionar Importação no main.dart

```dart
import 'screens/deposit_screen.dart';
```

## 2. Adicionar Rota no MaterialApp

Se estiver usando rotas nomeadas:

```dart
MaterialApp(
  title: 'Paga Conta',
  routes: {
    '/': (context) => const LoginScreen(),
    '/home': (context) => const HomeScreen(),
    '/deposit': (context) => const DepositScreen(),  // Nova rota
  },
)
```

## 3. Navegar para a Tela de Depósito

### Opção A: Usando Route Nomeada
```dart
// De qualquer lugar do app
Navigator.pushNamed(context, '/deposit');
```

### Opção B: Usando Navigator Direto
```dart
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (context) => const DepositScreen(),
  ),
);
```

## 4. Exemplo de Botão na HomeScreen

```dart
// Em home_screen.dart
import '../screens/deposit_screen.dart';

class HomeScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Home')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Outros widgets...
            
            ElevatedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const DepositScreen(),
                  ),
                );
              },
              icon: Icon(Icons.add_card),
              label: Text('Depositar Sats'),
              style: ElevatedButton.styleFrom(
                padding: EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 16,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

## 5. Exemplo de Card Clicável

```dart
Card(
  child: InkWell(
    onTap: () => Navigator.pushNamed(context, '/deposit'),
    child: Padding(
      padding: EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(Icons.flash_on, color: Colors.orange, size: 32),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Depositar Bitcoin',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Lightning ou On-chain',
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.arrow_forward_ios, size: 16),
        ],
      ),
    ),
  ),
)
```

## 6. Exemplo com FloatingActionButton

```dart
Scaffold(
  appBar: AppBar(title: Text('Carteira')),
  body: WalletBody(),
  floatingActionButton: FloatingActionButton.extended(
    onPressed: () => Navigator.pushNamed(context, '/deposit'),
    icon: Icon(Icons.add),
    label: Text('Depositar'),
    backgroundColor: Colors.orange,
  ),
)
```

## 7. Exemplo de Menu Drawer

```dart
Drawer(
  child: ListView(
    children: [
      DrawerHeader(
        decoration: BoxDecoration(color: Colors.orange),
        child: Text(
          'Paga Conta',
          style: TextStyle(
            color: Colors.white,
            fontSize: 24,
          ),
        ),
      ),
      ListTile(
        leading: Icon(Icons.home),
        title: Text('Início'),
        onTap: () => Navigator.pushNamed(context, '/home'),
      ),
      ListTile(
        leading: Icon(Icons.flash_on),
        title: Text('Depositar'),
        onTap: () => Navigator.pushNamed(context, '/deposit'),
      ),
      ListTile(
        leading: Icon(Icons.history),
        title: Text('Histórico'),
        onTap: () => Navigator.pushNamed(context, '/history'),
      ),
    ],
  ),
)
```

## 8. Exemplo de Bottom Navigation

```dart
class MainScreen extends StatefulWidget {
  @override
  _MainScreenState createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;
  
  final List<Widget> _screens = [
    HomeScreen(),
    DepositScreen(),
    HistoryScreen(),
    ProfileScreen(),
  ];
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        type: BottomNavigationBarType.fixed,
        items: [
          BottomNavigationBarItem(
            icon: Icon(Icons.home),
            label: 'Início',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.add_circle),
            label: 'Depositar',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.history),
            label: 'Histórico',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: 'Perfil',
          ),
        ],
      ),
    );
  }
}
```

## 9. Callback de Sucesso

Se precisar executar algo após depósito bem-sucedido:

```dart
// Opção 1: Usando Navigator Result
final result = await Navigator.push(
  context,
  MaterialPageRoute(
    builder: (context) => const DepositScreen(),
  ),
);

if (result == true) {
  // Depósito realizado com sucesso
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Depósito realizado!')),
  );
  // Atualizar saldo
  context.read<BreezProvider>().refreshBalance();
}

// No DepositScreen, ao finalizar:
Navigator.pop(context, true);
```

## 10. Pré-preencher Valor

Se quiser abrir a tela com um valor pré-definido:

```dart
// Modificar DepositScreen para aceitar parâmetro:
class DepositScreen extends StatefulWidget {
  final double? initialAmount;
  
  const DepositScreen({Key? key, this.initialAmount}) : super(key: key);
  
  @override
  State<DepositScreen> createState() => _DepositScreenState();
}

// No initState:
@override
void initState() {
  super.initState();
  if (widget.initialAmount != null) {
    _amountController.text = widget.initialAmount.toString();
  }
  // ...
}

// Usar:
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (context) => DepositScreen(initialAmount: 100.0),
  ),
);
```

## 11. Verificação de Estado do Provider

Antes de navegar, verificar se o Breez está inicializado:

```dart
void _navigateToDeposit() {
  final breezProvider = context.read<BreezProvider>();
  
  if (!breezProvider.isInitialized) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Inicializando carteira...'),
        backgroundColor: Colors.orange,
      ),
    );
    return;
  }
  
  Navigator.pushNamed(context, '/deposit');
}
```

## 12. Deep Link (Opcional)

Para abrir a tela via deep link:

```dart
// No MaterialApp
onGenerateRoute: (settings) {
  if (settings.name == '/deposit') {
    final args = settings.arguments as Map<String, dynamic>?;
    return MaterialPageRoute(
      builder: (context) => DepositScreen(
        initialAmount: args?['amount'],
      ),
    );
  }
  return null;
},

// Usar:
Navigator.pushNamed(
  context,
  '/deposit',
  arguments: {'amount': 50.0},
);
```

## Resumo

A forma mais simples de integrar:

```dart
// 1. Importar
import 'screens/deposit_screen.dart';

// 2. Adicionar botão onde quiser
ElevatedButton(
  onPressed: () {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const DepositScreen(),
      ),
    );
  },
  child: Text('Depositar'),
)
```

Pronto! A tela está integrada e funcionando.
