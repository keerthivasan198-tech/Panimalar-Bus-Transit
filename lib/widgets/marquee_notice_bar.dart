import 'dart:async';
import 'package:flutter/material.dart';

class MarqueeNoticeBar extends StatefulWidget {
  final String text;
  const MarqueeNoticeBar({super.key, required this.text});

  @override
  State<MarqueeNoticeBar> createState() => _MarqueeNoticeBarState();
}

class _MarqueeNoticeBarState extends State<MarqueeNoticeBar> {
  late ScrollController _scrollController;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startScrolling();
    });
  }

  void _startScrolling() {
    _timer = Timer.periodic(const Duration(milliseconds: 30), (timer) {
      if (!_scrollController.hasClients) return;

      final maxExtent = _scrollController.position.maxScrollExtent;
      final currentOffset = _scrollController.offset;

      if (maxExtent > 0) {
        if (currentOffset >= maxExtent) {
          _scrollController.jumpTo(0.0);
        } else {
          _scrollController.jumpTo(currentOffset + 0.8);
        }
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1E40AF), Color(0xFF2563EB)],
        ),
      ),
      child: SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: Row(
          children: [
            for (int i = 0; i < 5; i++)
              Padding(
                padding: const EdgeInsets.only(right: 60.0),
                child: Text(
                  widget.text,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
