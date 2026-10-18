import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../session/join_offers.dart';
import 'motion.dart';

/// The join prompt, top centre over the body: "Join Bob's server
/// (1.2.3.4:8080)?" with what its `/health` says (version, who is in,
/// the version gate, unreachable), Not now and Join. Shown while
/// [offers] has an offer (a clicked invite link, or one on the
/// clipboard).
class JoinOfferCard extends StatelessWidget {
  final JoinOffers offers;
  final VoidCallback onJoin;
  const JoinOfferCard({super.key, required this.offers, required this.onJoin});

  @override
  Widget build(BuildContext context) => SignalBuilder(builder: (context) {
        final o = offers.offer.value;
        return AnimatedSwitcher(
          duration: easeTime,
          switchInCurve: ease,
          switchOutCurve: ease,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, -0.2), end: Offset.zero).animate(a),
              child: child,
            ),
          ),
          child: o == null
              ? const SizedBox.shrink()
              : _OfferBody(key: ValueKey(o.link), offer: o, onJoin: onJoin, onDismiss: offers.dismiss),
        );
      });
}

class _OfferBody extends StatelessWidget {
  final JoinOffer offer;
  final VoidCallback onJoin;
  final VoidCallback onDismiss;
  const _OfferBody({super.key, required this.offer, required this.onJoin, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final h = offer.health;
    final problem = h != null && (!h.online || h.needsUpdate);
    final detail = h == null ? 'Checking the server…' : offer.detail;
    return Material(
      key: const ValueKey('join-offer'),
      elevation: 12,
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(offer.source == OfferSource.clipboard ? Icons.content_paste_go : Icons.link,
                  color: scheme.primary),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(offer.question,
                        key: const ValueKey('join-offer-question'),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (detail.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          [
                            if (offer.source == OfferSource.clipboard) 'Invite on your clipboard',
                            detail,
                          ].join(' · '),
                          style: TextStyle(
                              fontSize: 12, color: problem ? Colors.amber.shade300 : scheme.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              TextButton(key: const ValueKey('join-offer-dismiss'), onPressed: onDismiss, child: const Text('Not now')),
              const SizedBox(width: 4),
              FilledButton(key: const ValueKey('join-offer-join'), onPressed: onJoin, child: const Text('Join')),
            ],
          ),
        ),
      ),
    );
  }
}
