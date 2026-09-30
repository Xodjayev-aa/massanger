import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors.dart';
import 'social_models.dart';

/// The wallet: balance, ledger, cosmetics, custom tags, gifts and payouts.
///
/// Stars are the in-app currency and the ledger is append-only — the balance is
/// a materialised sum the server owns, never something a client can write. Real
/// money only enters through Stripe Checkout, which is why [checkout] talks to
/// the `stripe-checkout` edge function instead of inventing a payment row.
class WalletSummary {
  const WalletSummary({
    this.balance = 0,
    this.lifetimeIn = 0,
    this.lifetimeOut = 0,
    this.earnedFromGifts = 0,
    this.sentAsGifts = 0,
    this.tagCredits = 0,
  });

  final int balance;
  final int lifetimeIn;
  final int lifetimeOut;
  final int earnedFromGifts;
  final int sentAsGifts;
  final int tagCredits;

  factory WalletSummary.fromMap(Map<String, dynamic> map) => WalletSummary(
        balance: (map['balance'] as num?)?.toInt() ?? 0,
        lifetimeIn: (map['lifetime_in'] as num?)?.toInt() ?? 0,
        lifetimeOut: (map['lifetime_out'] as num?)?.toInt() ?? 0,
        earnedFromGifts: (map['earned_from_gifts'] as num?)?.toInt() ?? 0,
        sentAsGifts: (map['sent_as_gifts'] as num?)?.toInt() ?? 0,
        tagCredits: (map['tag_credits'] as num?)?.toInt() ?? 0,
      );
}

/// One line of the append-only ledger. `delta` is signed.
class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.delta,
    required this.reason,
    required this.createdAt,
    this.refType,
    this.refId,
    this.metadata = const <String, dynamic>{},
  });

  final String id;
  final int delta;
  final String reason;
  final DateTime createdAt;
  final String? refType;
  final String? refId;
  final Map<String, dynamic> metadata;

  bool get isCredit => delta > 0;

  factory LedgerEntry.fromMap(Map<String, dynamic> map) => LedgerEntry(
        id: '${map['id']}',
        delta: (map['delta'] as num?)?.toInt() ?? 0,
        reason: '${map['reason'] ?? ''}',
        createdAt: DateTime.tryParse('${map['created_at']}')?.toUtc() ?? DateTime.now().toUtc(),
        refType: map['ref_type'] as String?,
        refId: map['ref_id'] as String?,
        metadata: asMap(map['metadata']),
      );
}

/// A purchasable product. `stars` is what a top-up grants; `sku` `tag.custom`
/// grants the entitlement that minting a custom tag consumes.
class StoreProduct {
  const StoreProduct({
    required this.sku,
    required this.kind,
    required this.title,
    required this.priceCents,
    required this.currency,
    required this.stars,
    this.description,
    this.position = 100,
  });

  final String sku;
  final String kind;
  final String title;
  final String? description;
  final int priceCents;
  final String currency;
  final int stars;
  final int position;

  String get priceLabel => '\$${(priceCents / 100).toStringAsFixed(2)}';

  factory StoreProduct.fromMap(Map<String, dynamic> map) => StoreProduct(
        sku: '${map['sku']}',
        kind: '${map['kind'] ?? 'stars'}',
        title: '${map['title'] ?? ''}',
        description: map['description'] as String?,
        priceCents: (map['price_cents'] as num?)?.toInt() ?? 0,
        currency: '${map['currency'] ?? 'usd'}',
        stars: (map['stars'] as num?)?.toInt() ?? 0,
        position: (map['position'] as num?)?.toInt() ?? 100,
      );
}

/// The shop window: top-ups, the tag unlock and the cosmetics shelf.
class StoreCatalog {
  const StoreCatalog({
    this.products = const <StoreProduct>[],
    this.tagMint,
    this.cosmetics = const <CosmeticSummary>[],
    this.ownedCosmetics = const <String>[],
  });

  final List<StoreProduct> products;
  final StoreProduct? tagMint;
  final List<CosmeticSummary> cosmetics;
  final List<String> ownedCosmetics;

  factory StoreCatalog.fromMap(Map<String, dynamic> map) {
    final mint = map['tag_mint'];
    return StoreCatalog(
      products: asMapList(map['stars']).map(StoreProduct.fromMap).toList(growable: false),
      tagMint: mint is Map ? StoreProduct.fromMap(asMap(mint)) : null,
      cosmetics: asMapList(map['cosmetics']).map(CosmeticSummary.fromMap).toList(growable: false),
      ownedCosmetics: asMapList(map['mine'])
          .map((row) => '${row['cosmetic_id']}')
          .toList(growable: false),
    );
  }
}

/// A completed or pending real-money payment.
class PaymentEntry {
  const PaymentEntry({
    required this.id,
    required this.sku,
    required this.status,
    required this.amountCents,
    required this.currency,
    required this.createdAt,
    this.starsGranted = 0,
    this.paidAt,
  });

  final String id;
  final String sku;
  final String status;
  final int amountCents;
  final String currency;
  final DateTime createdAt;
  final int starsGranted;
  final DateTime? paidAt;

  String get amountLabel => '\$${(amountCents / 100).toStringAsFixed(2)}';

  factory PaymentEntry.fromMap(Map<String, dynamic> map) => PaymentEntry(
        id: '${map['id']}',
        sku: '${map['sku']}',
        status: '${map['status']}',
        amountCents: (map['amount_cents'] as num?)?.toInt() ?? 0,
        currency: '${map['currency'] ?? 'usd'}',
        starsGranted: (map['stars_granted'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse('${map['created_at']}')?.toUtc() ?? DateTime.now().toUtc(),
        paidAt: map['paid_at'] == null ? null : DateTime.tryParse('${map['paid_at']}')?.toUtc(),
      );
}

/// A Stripe Checkout Session, ready to open in a browser.
class CheckoutSession {
  const CheckoutSession({
    required this.sessionId,
    required this.url,
    this.paymentId,
    this.amountCents = 0,
    this.currency = 'usd',
    this.stars = 0,
  });

  final String sessionId;
  final String url;
  final String? paymentId;
  final int amountCents;
  final String currency;
  final int stars;
}

/// A directed gift — the tip that moves Stars from one wallet to another.
class GiftEntry {
  const GiftEntry({
    required this.id,
    required this.stars,
    required this.kind,
    required this.createdAt,
    this.note,
    this.isAnonymous = false,
    this.senderName,
    this.senderUsername,
    this.senderAvatar,
  });

  final String id;
  final int stars;
  final String kind;
  final DateTime createdAt;
  final String? note;
  final bool isAnonymous;
  final String? senderName;
  final String? senderUsername;
  final String? senderAvatar;

  factory GiftEntry.fromMap(Map<String, dynamic> map) => GiftEntry(
        id: '${map['id']}',
        stars: (map['stars'] as num?)?.toInt() ?? 0,
        kind: '${map['kind'] ?? 'gift'}',
        createdAt: DateTime.tryParse('${map['created_at']}')?.toUtc() ?? DateTime.now().toUtc(),
        note: map['note'] as String?,
        isAnonymous: map['is_anonymous'] == true,
        senderName: map['sender_name'] as String?,
        senderUsername: map['sender_username'] as String?,
        senderAvatar: map['sender_avatar'] as String?,
      );
}

class EconomyRepository {
  EconomyRepository(this._client);

  final SupabaseClient _client;

  // ---------------------------------------------------------------------------
  // wallet
  // ---------------------------------------------------------------------------

  Future<WalletSummary> wallet() async {
    try {
      final data = await _client.rpc('wallet_summary');
      return WalletSummary.fromMap(asMap(data));
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<LedgerEntry>> ledger({int limit = 40}) async {
    try {
      final rows = await _client.rpc('star_ledger_list', params: {'p_limit': limit});
      return asMapList(rows).map(LedgerEntry.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  // ---------------------------------------------------------------------------
  // store
  // ---------------------------------------------------------------------------

  Future<StoreCatalog> catalog() async {
    try {
      final data = await _client.rpc('store_catalog');
      return StoreCatalog.fromMap(asMap(data));
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> buyCosmetic(String slug) async {
    try {
      await _client.rpc('cosmetic_buy', params: {'p_slug': slug});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> equipCosmetic(String cosmeticId, {bool equipped = true}) async {
    try {
      await _client.rpc('cosmetic_equip', params: {
        'p_cosmetic_id': cosmeticId,
        'p_equipped': equipped,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  // ---------------------------------------------------------------------------
  // custom tags (the $2.49 product)
  // ---------------------------------------------------------------------------

  /// Spends a `tag_mint` credit when the buyer has one, otherwise Stars at the
  /// advertised rate. Returns the new tag id.
  Future<String> mintTag({
    required String text,
    Map<String, dynamic> style = const <String, dynamic>{},
    String? styleId,
    String? emoji,
    int slot = 0,
  }) async {
    try {
      final id = await _client.rpc('mint_tag', params: <String, Object?>{
        'p_text': text,
        'p_style': style,
        'p_style_id': styleId,
        'p_emoji': emoji,
        'p_slot': slot,
      });
      return '$id';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> updateTag(
    String tagId, {
    String? text,
    Map<String, dynamic>? style,
    String? styleId,
    String? emoji,
    int? slot,
    bool? active,
  }) async {
    try {
      await _client.rpc('tag_update', params: <String, Object?>{
        'p_tag_id': tagId,
        'p_text': text,
        'p_style': style,
        'p_style_id': styleId,
        'p_emoji': emoji,
        'p_slot': slot,
        'p_active': active,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> deleteTag(String tagId) async {
    try {
      await _client.rpc('tag_delete', params: {'p_tag_id': tagId});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  // ---------------------------------------------------------------------------
  // gifts, payouts, payments
  // ---------------------------------------------------------------------------

  Future<void> sendGift({
    required String recipientId,
    required int stars,
    String kind = 'gift',
    String? videoId,
    String? shortId,
    String? chatId,
    String? messageId,
    String? note,
    bool anonymous = false,
  }) async {
    try {
      await _client.rpc('gift_send', params: <String, Object?>{
        'p_recipient_id': recipientId,
        'p_stars': stars,
        'p_kind': kind,
        'p_video_id': videoId,
        'p_short_id': shortId,
        'p_chat_id': chatId,
        'p_message_id': messageId,
        'p_note': note,
        'p_anonymous': anonymous,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<GiftEntry>> giftsReceived({int limit = 50}) async {
    try {
      final rows = await _client.rpc('gifts_received', params: {'p_limit': limit});
      return asMapList(rows).map(GiftEntry.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// The minimum is enforced server-side (1000⭐) — an automatic payout rail
  /// would need a payment licence, so requests are settled by the operator.
  Future<void> requestPayout(int stars, {String? details}) async {
    try {
      await _client.rpc('payout_request', params: {'p_stars': stars, 'p_details': details});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<Map<String, dynamic>>> payouts() async {
    try {
      final rows = await _client.rpc('payout_requests_list');
      return asMapList(rows);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<PaymentEntry>> payments({int limit = 30}) async {
    try {
      final rows = await _client.rpc('payment_list', params: {'p_limit': limit});
      return asMapList(rows).map(PaymentEntry.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<Map<String, dynamic>>> refunds({int limit = 30}) async {
    try {
      final rows = await _client.rpc('payment_refund_list', params: {'p_limit': limit});
      return asMapList(rows);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  // ---------------------------------------------------------------------------
  // Stripe
  // ---------------------------------------------------------------------------

  /// True when this deployment can take money at all. The app hides the top-up
  /// button when it cannot, instead of offering a checkout that 500s.
  Future<({bool configured, String? mode})> paymentsConfigured() async {
    try {
      final response = await _client.functions.invoke('stripe-checkout', body: <String, Object?>{
        'action': 'status',
      });
      final data = asMap(response.data is Map ? (response.data as Map)['data'] : null);
      return (configured: data['configured'] == true, mode: data['mode'] as String?);
    } catch (_) {
      return (configured: false, mode: null);
    }
  }

  /// Mints a Checkout Session for a listed product. [requestId] is a uuid the
  /// caller keeps for the attempt, so a double tap reuses the same session
  /// instead of charging twice.
  Future<CheckoutSession> checkout({required String sku, required String requestId}) async {
    try {
      final response = await _client.functions.invoke('stripe-checkout', body: <String, Object?>{
        'action': 'create',
        'sku': sku,
        'requestId': requestId,
      });
      final data = asMap(response.data is Map ? (response.data as Map)['data'] : null);
      final url = data['url'];
      if (url is! String || url.isEmpty) {
        throw const AppException('payments', 'The checkout page could not be created. Try again.');
      }
      return CheckoutSession(
        sessionId: '${data['sessionId']}',
        url: url,
        paymentId: data['paymentId'] as String?,
        amountCents: (data['amountCents'] as num?)?.toInt() ?? 0,
        currency: '${data['currency'] ?? 'usd'}',
        stars: (data['stars'] as num?)?.toInt() ?? 0,
      );
    } on AppException {
      rethrow;
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Asks Stripe directly what happened to a session. This is the honest
  /// fallback when the webhook cannot reach this deployment (local development,
  /// or an endpoint that was down past Stripe's retry window).
  Future<bool> syncCheckout(String sessionId) async {
    try {
      final response = await _client.functions.invoke('stripe-checkout', body: <String, Object?>{
        'action': 'sync',
        'sessionId': sessionId,
      });
      final data = asMap(response.data is Map ? (response.data as Map)['data'] : null);
      return data['reconciled'] == true;
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }
}
