import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../app/brand.dart';
import '../../app/di.dart';
import '../../app/router.dart';
import '../../core/errors.dart';
import '../../data/economy_repository.dart';
import '../chats/widgets.dart';

/// The store: Stars top-ups, the custom-tag unlock and the cosmetics shelf.
///
/// Money rules this screen obeys, because getting them wrong is how a store
/// becomes a scam:
///
/// * nothing is granted client-side — the row in `payments` is created by the
///   server, the Stripe webhook settles it, and this page only ever *reads*;
/// * a checkout that has not been paid yet shows as pending, not as owned;
/// * when the deployment has no Stripe keys, the button says so instead of
///   opening a flow that cannot finish.
class StorePage extends StatefulWidget {
  const StorePage({super.key});

  @override
  State<StorePage> createState() => _StorePageState();
}

class _StorePageState extends State<StorePage> {
  StoreCatalog? _catalog;
  WalletSummary? _wallet;
  bool _paymentsReady = false;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final economy = sl<EconomyRepository>();
      final catalog = await economy.catalog();
      final wallet = await economy.wallet();
      final configured = await economy.paymentsConfigured();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _wallet = wallet;
        _paymentsReady = configured.configured;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is AppException ? error.message : 'The store could not be loaded.';
      });
    }
  }

  Future<void> _buy(StoreProduct product) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final economy = sl<EconomyRepository>();
      final session = await economy.checkout(sku: product.sku, requestId: const Uuid().v4());
      if (!mounted) return;
      final opened = await _openCheckout(session.url);
      if (!mounted) return;
      if (!opened) {
        await _showLinkSheet(session);
        return;
      }
      // Stripe has the browser now. The webhook settles the balance; this is
      // only a courtesy poll so a fast card does not need a manual refresh.
      await _poll(session.sessionId);
    } on AppException catch (error) {
      _toast(error.message);
    } catch (_) {
      _toast('Checkout could not be started.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _openCheckout(String url) async {
    try {
      return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  Future<void> _showLinkSheet(CheckoutSession session) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Finish the payment', style: Theme.of(sheetContext).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Open this secure Stripe link in a browser, then come back. Stars appear as soon as Stripe confirms the payment.',
              style: TextStyle(fontSize: 13, color: Theme.of(sheetContext).colorScheme.onSurfaceVariant, height: 1.4),
            ),
            const SizedBox(height: 12),
            SelectableText(session.url, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: session.url));
                      if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                      _toast('Link copied.');
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('Copy link'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () async {
                      Navigator.of(sheetContext).pop();
                      await _poll(session.sessionId);
                    },
                    child: const Text('I have paid'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _poll(String sessionId) async {
    final economy = sl<EconomyRepository>();
    for (var attempt = 0; attempt < 4; attempt++) {
      await Future<void>.delayed(Duration(seconds: attempt == 0 ? 1 : 3));
      try {
        final paid = await economy.syncCheckout(sessionId);
        if (paid) {
          _toast('Stars added to your wallet.');
          await _load();
          return;
        }
      } catch (_) {
        // A poll failure is not a payment failure; the webhook still owns the
        // truth and the wallet reload below picks it up either way.
      }
    }
    if (mounted) {
      _toast('Payment is still pending. Pull the wallet to refresh in a moment.');
      await _load();
    }
  }

  Future<void> _mintTag() async {
    final catalog = _catalog;
    if (catalog == null) return;
    final draft = await showModalBottomSheet<_TagDraft>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _TagMintSheet(styles: catalog.tagStyles, tagMint: catalog.tagMint),
    );
    if (draft == null) return;
    try {
      await sl<EconomyRepository>().mintTag(
        text: draft.text,
        emoji: draft.emoji,
        styleId: draft.styleId,
        slot: draft.slot,
      );
      _toast('Tag “${draft.text}” is live on your profile.');
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _buyCosmetic(CosmeticSummary cosmetic) async {
    try {
      final economy = sl<EconomyRepository>();
      await economy.buyCosmetic(cosmetic.slug);
      await economy.equipCosmetic(cosmetic.id);
      _toast('${cosmetic.name} is yours.');
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _toggleEquip(CosmeticSummary cosmetic) async {
    try {
      await sl<EconomyRepository>().equipCosmetic(cosmetic.id, equipped: !cosmetic.equipped);
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final catalog = _catalog;
    final wallet = _wallet;
    return Scaffold(
      appBar: AppBar(
        title: const BrandLockup(size: 24),
        actions: <Widget>[
          IconButton(
            tooltip: 'Wallet',
            icon: const Icon(Icons.account_balance_wallet_outlined),
            onPressed: () => context.push(Routes.wallet),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : catalog == null || wallet == null
              ? InlineError(message: _error ?? 'The store could not be loaded.', onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                    children: <Widget>[
                      _BalanceCard(wallet: wallet, onTap: () => context.push(Routes.wallet)),
                      const SizedBox(height: 18),
                      if (!_paymentsReady)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: InlineError(
                            message: 'Card payments are not configured on this deployment yet. '
                                'Stars can still be earned from gifts and spent in the store.',
                          ),
                        ),
                      _TagHero(
                        tagMint: catalog.tagMint,
                        credits: wallet.tagCredits,
                        onMint: _mintTag,
                      ),
                      const SizedBox(height: 22),
                      _SectionTitle('Stars', trailing: 'Payment via Stripe'),
                      if (catalog.products.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text('No top-up packs are on sale right now.', style: TextStyle(fontSize: 13)),
                        )
                      else
                        for (final product in catalog.products) ...<Widget>[
                          _ProductRow(
                            product: product,
                            enabled: _paymentsReady && !_busy,
                            onBuy: () => _buy(product),
                          ),
                          const SizedBox(height: 8),
                        ],
                      const SizedBox(height: 18),
                      _SectionTitle('Tag styles', trailing: 'Cosmetic only'),
                      if (catalog.tagStyles.isEmpty)
                        const Text('No styles are on sale right now.', style: TextStyle(fontSize: 13))
                      else
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: <Widget>[
                            for (final style in catalog.tagStyles)
                              _StyleChip(
                                style: style,
                                owned: catalog.ownedCosmetics.contains(style.id),
                                onBuy: () => _buyCosmetic(style),
                                onEquip: () => _toggleEquip(style),
                              ),
                          ],
                        ),
                      const SizedBox(height: 22),
                      _SectionTitle('Cosmetics', trailing: 'Badges and frames'),
                      for (final cosmetic in catalog.cosmetics)
                        _CosmeticRow(
                          cosmetic: cosmetic,
                          onBuy: () => _buyCosmetic(cosmetic),
                          onEquip: () => _toggleEquip(cosmetic),
                        ),
                    ],
                  ),
                ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: <Widget>[
          Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const Spacer(),
          if (trailing != null)
            Text(trailing!, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.wallet, required this.onTap});

  final WalletSummary wallet;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(gradient: Brand.gradient, borderRadius: BorderRadius.circular(18)),
        child: Row(
          children: <Widget>[
            const Icon(Icons.star_rounded, color: Colors.white, size: 34),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '${wallet.balance}',
                    style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800),
                  ),
                  const Text('Stars in your wallet', style: TextStyle(color: Colors.white70, fontSize: 12.5)),
                ],
              ),
            ),
            if (wallet.tagCredits > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(20)),
                child: Text(
                  '${wallet.tagCredits} tag credit${wallet.tagCredits == 1 ? '' : 's'}',
                  style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The $2.49 product, stated plainly: one tag, minted once, worn next to your
/// name everywhere.
class _TagHero extends StatelessWidget {
  const _TagHero({required this.tagMint, required this.credits, required this.onMint});

  final StoreProduct? tagMint;
  final int credits;
  final VoidCallback onMint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final price = tagMint == null ? '—' : _money(tagMint!.priceCents, tagMint!.currency);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Brand.gold.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.local_offer_rounded, color: Brand.gold, size: 20),
              const SizedBox(width: 8),
              const Text('Custom tag', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const Spacer(),
              Text(
                credits > 0 ? '1 credit ready' : price,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            tagMint?.description ??
                'A tag like [GRAND] or [NIGHT OWL] rendered next to your name on every comment, video and message.',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onMint,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: Text(credits > 0 ? 'Mint a tag with your credit' : 'Mint a tag ($price)'),
          ),
        ],
      ),
    );
  }
}

String _money(int cents, String currency) {
  final symbol = switch (currency.toLowerCase()) {
    'usd' => r'$',
    'eur' => '€',
    _ => '',
  };
  final value = (cents / 100).toStringAsFixed(2);
  return symbol.isEmpty ? '$value ${currency.toUpperCase()}' : '$symbol$value';
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({required this.product, required this.enabled, required this.onBuy});

  final StoreProduct product;
  final bool enabled;
  final VoidCallback onBuy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.star_rounded, color: Brand.gold),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(product.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  '${product.stars} Stars${product.description == null ? '' : ' · ${product.description}'}',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          FilledButton(
            onPressed: enabled ? onBuy : null,
            child: Text(_money(product.priceCents, product.currency)),
          ),
        ],
      ),
    );
  }
}

class _StyleChip extends StatelessWidget {
  const _StyleChip({required this.style, required this.owned, required this.onBuy, required this.onEquip});

  final CosmeticSummary style;
  final bool owned;
  final VoidCallback onBuy;
  final VoidCallback onEquip;

  @override
  Widget build(BuildContext context) {
    final colors = _gradientColors(style.style);
    return InkWell(
      onTap: owned ? onEquip : onBuy,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: colors),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '[${style.name.toUpperCase()}]',
              style: TextStyle(
                color: _textColor(style.style),
                fontWeight: FontWeight.w800,
                fontSize: 13,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              owned ? (style.equipped ? 'Equipped' : 'Tap to equip') : '${style.priceStars} Stars',
              style: TextStyle(color: _textColor(style.style).withOpacity(0.8), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

List<Color> _gradientColors(Map<String, dynamic> style) {
  final raw = style['gradient'];
  if (raw is List && raw.length >= 2) {
    final colors = raw.map(_parseColor).whereType<Color>().toList(growable: false);
    if (colors.length >= 2) return colors;
  }
  return const <Color>[Color(0xFF2B2F36), Color(0xFF14161A)];
}

Color _parseColor(Object? value) {
  final text = '$value'.replaceFirst('#', '');
  if (text.length != 6) return const Color(0xFF2B2F36);
  final parsed = int.tryParse(text, radix: 16);
  return parsed == null ? const Color(0xFF2B2F36) : Color(0xFF000000 | parsed);
}

/// The style map carries its own text colour because a gradient that reads
/// well on paper can leave white text invisible on a bright fill.
Color _textColor(Map<String, dynamic> style) =>
    style['text'] == null ? Colors.white : _parseColor(style['text']);

class _CosmeticRow extends StatelessWidget {
  const _CosmeticRow({required this.cosmetic, required this.onBuy, required this.onEquip});

  final CosmeticSummary cosmetic;
  final VoidCallback onBuy;
  final VoidCallback onEquip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: scheme.surfaceContainerHighest,
        child: Text(
          cosmetic.kind == 'badge' ? '★' : '◈',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      ),
      title: Text(cosmetic.name),
      subtitle: Text(
        '${cosmetic.rarity} · ${cosmetic.description ?? cosmetic.kind}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: cosmetic.owned
          ? TextButton(onPressed: onEquip, child: Text(cosmetic.equipped ? 'On' : 'Equip'))
          : FilledButton.tonal(
              onPressed: onBuy,
              child: Text('${cosmetic.priceStars} ★'),
            ),
    );
  }
}

class _TagDraft {
  const _TagDraft({required this.text, required this.slot, this.emoji, this.styleId});

  final String text;
  final int slot;
  final String? emoji;
  final String? styleId;
}

class _TagMintSheet extends StatefulWidget {
  const _TagMintSheet({required this.styles, required this.tagMint});

  final List<CosmeticSummary> styles;
  final StoreProduct? tagMint;

  @override
  State<_TagMintSheet> createState() => _TagMintSheetState();
}

class _TagMintSheetState extends State<_TagMintSheet> {
  static const List<String> _emoji = <String>['', '🔥', '⚡', '🌙', '👑', '🎯', '💎', '🚀', '🧊'];

  final TextEditingController _text = TextEditingController();
  String _emojiChoice = '';
  String? _styleId;
  int _slot = 0;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = _text.text.trim().toUpperCase();
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Mint a custom tag', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Up to 16 characters: A–Z, 0–9, space, dash and underscore. It is cleaned server-side, '
            'so the badge you see here is exactly what everybody else will see.',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _text,
            autofocus: true,
            maxLength: 16,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Tag text', counterText: ''),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          if (preview.isNotEmpty)
            Center(
              child: TagChip(
                tag: TagSummary(
                  id: 'preview',
                  text: preview,
                  emoji: _emojiChoice.isEmpty ? null : _emojiChoice,
                  style: _stylePreview(),
                ),
              ),
            ),
          const SizedBox(height: 14),
          Text('Emoji', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: <Widget>[
              for (final emoji in _emoji)
                ChoiceChip(
                  label: Text(emoji.isEmpty ? 'None' : emoji),
                  selected: _emojiChoice == emoji,
                  onSelected: (_) => setState(() => _emojiChoice = emoji),
                ),
            ],
          ),
          if (widget.styles.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            Text('Style', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final style in widget.styles)
                  ChoiceChip(
                    label: Text(style.name),
                    selected: _styleId == style.id,
                    onSelected: (_) => setState(() => _styleId = style.id),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: DropdownButtonFormField<int>(
                  value: _slot,
                  decoration: const InputDecoration(labelText: 'Slot'),
                  items: <DropdownMenuItem<int>>[
                    for (var index = 0; index < 5; index++)
                      DropdownMenuItem<int>(value: index, child: Text('${index + 1}')),
                  ],
                  onChanged: (value) => setState(() => _slot = value ?? 0),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: preview.isEmpty ? null : () => Navigator.of(context).pop(
                  _TagDraft(
                    text: preview,
                    slot: _slot,
                    emoji: _emojiChoice.isEmpty ? null : _emojiChoice,
                    styleId: _styleId,
                  ),
                ),
            child: const Text('Mint tag'),
          ),
        ],
      ),
    );
  }

  Map<String, dynamic> _stylePreview() {
    final id = _styleId;
    if (id == null) return const <String, dynamic>{};
    for (final style in widget.styles) {
      if (style.id == id) return style.style;
    }
    return const <String, dynamic>{};
  }
}

/// Wallet: what you hold, where it came from, and how to take it out.
class WalletPage extends StatefulWidget {
  const WalletPage({super.key});

  @override
  State<WalletPage> createState() => _WalletPageState();
}

class _WalletPageState extends State<WalletPage> {
  WalletSummary? _wallet;
  List<LedgerEntry> _ledger = const <LedgerEntry>[];
  List<GiftEntry> _gifts = const <GiftEntry>[];
  List<PaymentEntry> _payments = const <PaymentEntry>[];
  List<Map<String, dynamic>> _payouts = const <Map<String, dynamic>>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final economy = sl<EconomyRepository>();
      final wallet = await economy.wallet();
      final ledger = await economy.ledger(limit: 40);
      final gifts = await economy.giftsReceived(limit: 20);
      final payments = await economy.payments(limit: 20);
      final payouts = await economy.payouts();
      if (!mounted) return;
      setState(() {
        _wallet = wallet;
        _ledger = ledger;
        _gifts = gifts;
        _payments = payments;
        _payouts = payouts;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is AppException ? error.message : 'The wallet could not be loaded.';
      });
    }
  }

  Future<void> _requestPayout() async {
    final wallet = _wallet;
    if (wallet == null) return;
    final controller = TextEditingController();
    final stars = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cash out Stars'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'You can request up to ${wallet.balance} Stars. A payout is reviewed by a human before it leaves.',
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Stars'),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(int.tryParse(controller.text.trim())),
            child: const Text('Request'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (stars == null || stars <= 0) return;
    try {
      await sl<EconomyRepository>().requestPayout(stars);
      _toast('Payout requested.');
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _syncPayment(PaymentEntry payment) async {
    try {
      final paid = await sl<EconomyRepository>().syncCheckout(payment.id);
      _toast(paid ? 'Payment confirmed — Stars added.' : 'Stripe still says this payment is open.');
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final wallet = _wallet;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallet'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Store',
            icon: const Icon(Icons.storefront_rounded),
            onPressed: () => context.push(Routes.store),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : wallet == null
              ? InlineError(message: _error ?? 'The wallet could not be loaded.', onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(child: _Metric(label: 'Balance', value: '${wallet.balance} ★')),
                          Expanded(child: _Metric(label: 'Earned', value: '${wallet.lifetimeIn} ★')),
                          Expanded(child: _Metric(label: 'Spent', value: '${wallet.lifetimeOut} ★')),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: <Widget>[
                          Expanded(child: _Metric(label: 'From gifts', value: '${wallet.earnedFromGifts} ★')),
                          Expanded(child: _Metric(label: 'Gifted out', value: '${wallet.sentAsGifts} ★')),
                          Expanded(child: _Metric(label: 'Tag credits', value: '${wallet.tagCredits}')),
                        ],
                      ),
                      const SizedBox(height: 18),
                      FilledButton.tonalIcon(
                        onPressed: _requestPayout,
                        icon: const Icon(Icons.payments_outlined, size: 18),
                        label: const Text('Request a payout'),
                      ),
                      const SizedBox(height: 22),
                      const _WalletHeader('Recent activity'),
                      if (_ledger.isEmpty)
                        const Text('No Stars have moved yet.', style: TextStyle(fontSize: 13))
                      else
                        for (final entry in _ledger) _LedgerRow(entry: entry),
                      if (_gifts.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 22),
                        const _WalletHeader('Gifts received'),
                        for (final gift in _gifts) _GiftRow(gift: gift),
                      ],
                      if (_payments.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 22),
                        const _WalletHeader('Payments'),
                        for (final payment in _payments)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              payment.status == 'paid' ? Icons.check_circle_rounded : Icons.schedule_rounded,
                              color: payment.status == 'paid' ? Colors.green : Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                            title: Text(payment.sku),
                            subtitle: Text(
                              '${_money(payment.amountCents, payment.currency)} · ${payment.status}'
                              '${payment.starsGranted > 0 ? ' · +${payment.starsGranted} ★' : ''}',
                            ),
                            trailing: payment.status == 'paid'
                                ? null
                                : TextButton(onPressed: () => _syncPayment(payment), child: const Text('Check')),
                          ),
                      ],
                      if (_payouts.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 22),
                        const _WalletHeader('Payouts'),
                        for (final payout in _payouts)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text('${payout['stars'] ?? '—'} ★'),
                            subtitle: Text('${payout['status'] ?? 'requested'}'),
                          ),
                      ],
                    ],
                  ),
                ),
    );
  }
}

class _WalletHeader extends StatelessWidget {
  const _WalletHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      );
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        Text(label, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}

class _LedgerRow extends StatelessWidget {
  const _LedgerRow({required this.entry});

  final LedgerEntry entry;

  @override
  Widget build(BuildContext context) {
    final positive = entry.delta >= 0;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        positive ? Icons.add_circle_outline_rounded : Icons.remove_circle_outline_rounded,
        color: positive ? Colors.green : Theme.of(context).colorScheme.error,
      ),
      title: Text(entry.reason.replaceAll('_', ' ')),
      subtitle: Text(relativeTime(entry.createdAt)),
      trailing: Text(
        '${positive ? '+' : ''}${entry.delta} ★',
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: positive ? Colors.green : Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }
}

class _GiftRow extends StatelessWidget {
  const _GiftRow({required this.gift});

  final GiftEntry gift;

  @override
  Widget build(BuildContext context) {
    final from = gift.isAnonymous
        ? 'Anonymous'
        : (gift.senderName ?? gift.senderUsername ?? 'Someone');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: gift.senderAvatar == null
          ? const CircleAvatar(child: Icon(Icons.star_rounded))
          : PersonAvatar(name: from, path: gift.senderAvatar, size: 36),
      title: Text('$from sent ${gift.stars} ★'),
      subtitle: Text(gift.note?.isNotEmpty == true ? gift.note! : relativeTime(gift.createdAt)),
    );
  }
}
