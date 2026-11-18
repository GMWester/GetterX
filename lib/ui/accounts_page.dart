import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app/controller.dart';

import 'package:getterx_core/auth.dart';
import 'package:getterx_core/sources/source.dart';

import 'common.dart';

/// Compile-time default for "Sign in with GitHub":
/// flutter build ... --dart-define=GITHUB_CLIENT_ID=Iv1.xxxxx
const _builtInGithubClientId = String.fromEnvironment('GITHUB_CLIENT_ID');

class AccountsPage extends StatelessWidget {
  final AppController c;
  const AccountsPage(this.c, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final cr = c.credentials;
        final st = c.settings;
        return Scaffold(
          appBar: AppBar(title: const Text('Accounts (optional)')),
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              const Card(
                child: ListTile(
                  leading: Icon(Icons.shield_outlined),
                  title: Text('How your logins are protected'),
                  subtitle: Text(
                    'Passwords are never stored. Only the resulting token/key is kept, encrypted in your system\'s '
                    'credential store (Keychain / Android Keystore / Windows Credential Manager / Secret Service). '
                    'Each token is only ever sent over HTTPS to its own service and is removed from logs and errors. '
                    'Use read-only tokens where possible.',
                  ),
                  isThreeLine: true,
                ),
              ),
              _ServiceCard(
                icon: Icons.code,
                title: 'GitHub',
                purpose: 'Private repositories and a higher API limit (5000 instead of 60 requests/hour).',
                signedInAs: cr.githubToken.isEmpty ? null : (st.githubUser.isEmpty ? 'token saved' : st.githubUser),
                actions: [
                  FilledButton.icon(
                    onPressed: () => _githubDevice(context),
                    icon: const Icon(Icons.login),
                    label: const Text('Sign in with GitHub'),
                  ),
                  OutlinedButton(
                    onPressed: () => _pasteToken(
                      context,
                      title: 'GitHub token',
                      help:
                          'Recommended: a fine-grained token with read-only "Contents" access to just the repos you need.\n'
                          'github.com → Settings → Developer settings → Personal access tokens.',
                      helpUrl: 'https://github.com/settings/personal-access-tokens/new',
                      validate: (t) => c.auth.githubUser(t),
                      save: (t, user) async {
                        await c.setCredentials(c.credentials.copyWith(githubToken: t));
                        st.githubUser = user;
                        await c.saveSettings();
                      },
                    ),
                    child: const Text('Use a token'),
                  ),
                ],
                onSignOut: () async {
                  await c.setCredentials(c.credentials.copyWith(githubToken: ''));
                  st.githubUser = '';
                  await c.saveSettings();
                  if (context.mounted) {
                    toast(
                      context,
                      'Signed out. To fully revoke access, also delete the token / app authorization on github.com.',
                    );
                  }
                },
              ),
              _ServiceCard(
                icon: Icons.videogame_asset,
                title: 'itch.io',
                purpose: 'Required for itch.io. Free games work with any account; purchased games download with the account that owns them.',
                signedInAs: cr.itchApiKey.isEmpty ? null : (st.itchUser.isEmpty ? 'key saved' : st.itchUser),
                actions: [
                  FilledButton.icon(
                    onPressed: () => _itchLogin(context),
                    icon: const Icon(Icons.login),
                    label: const Text('Sign in'),
                  ),
                  OutlinedButton(
                    onPressed: () => _pasteToken(
                      context,
                      title: 'itch.io API key',
                      help: 'itch.io → Settings → API keys → Generate new API key.',
                      helpUrl: 'https://itch.io/user/settings/api-keys',
                      validate: (t) => c.auth.itchUser(t),
                      save: (t, user) async {
                        await c.setCredentials(c.credentials.copyWith(itchApiKey: t));
                        st.itchUser = user;
                        await c.saveSettings();
                      },
                    ),
                    child: const Text('Use an API key'),
                  ),
                ],
                onSignOut: () async {
                  await c.setCredentials(c.credentials.copyWith(itchApiKey: ''));
                  st.itchUser = '';
                  await c.saveSettings();
                  if (context.mounted) {
                    toast(context, 'Signed out. You can revoke the key at itch.io/user/settings/api-keys.');
                  }
                },
              ),
              _ServiceCard(
                icon: Icons.extension,
                title: 'Modrinth',
                purpose: 'Only needed for private, unlisted or draft projects.',
                signedInAs: cr.modrinthToken.isEmpty
                    ? null
                    : (st.modrinthUser.isEmpty ? 'token saved' : st.modrinthUser),
                actions: [
                  OutlinedButton(
                    onPressed: () => _pasteToken(
                      context,
                      title: 'Modrinth personal access token',
                      help: 'modrinth.com → Settings → Personal access tokens. Give it only "Read projects" and "Read versions".',
                      helpUrl: 'https://modrinth.com/settings/pats',
                      validate: (t) => c.auth.modrinthUser(t),
                      save: (t, user) async {
                        await c.setCredentials(c.credentials.copyWith(modrinthToken: t));
                        st.modrinthUser = user;
                        await c.saveSettings();
                      },
                    ),
                    child: const Text('Use a token'),
                  ),
                ],
                onSignOut: () async {
                  await c.setCredentials(c.credentials.copyWith(modrinthToken: ''));
                  st.modrinthUser = '';
                  await c.saveSettings();
                },
              ),
              _ServiceCard(
                icon: Icons.local_fire_department,
                title: 'CurseForge',
                purpose:
                    'CurseForge has no user login for downloads. An API key (free) uses the official API; '
                    'without one a public mirror of the API is used.',
                signedInAs: cr.curseforgeApiKey.isEmpty ? null : 'API key saved',
                actions: [
                  OutlinedButton(
                    onPressed: () => _pasteToken(
                      context,
                      title: 'CurseForge API key',
                      help: 'Create a free key at console.curseforge.com.',
                      helpUrl: 'https://console.curseforge.com/',
                      validate: (t) async {
                        await getJson(
                          c.client,
                          Uri.parse('https://api.curseforge.com/v1/games/432'),
                          headers: {'x-api-key': t},
                        );
                        return 'ok';
                      },
                      save: (t, _) => c.setCredentials(c.credentials.copyWith(curseforgeApiKey: t)),
                    ),
                    child: const Text('Use an API key'),
                  ),
                ],
                onSignOut: () => c.setCredentials(c.credentials.copyWith(curseforgeApiKey: '')),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pasteToken(
    BuildContext context, {
    required String title,
    required String help,
    required String helpUrl,
    required Future<String> Function(String) validate,
    required Future<void> Function(String token, String user) save,
  }) async {
    final ctl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        var busy = false;
        String? err;
        return StatefulBuilder(
          builder: (ctx, set) {
            return AlertDialog(
              title: Text(title),
              content: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(help),
                    TextButton(onPressed: () => openUrl(helpUrl), child: const Text('Open the page')),
                    TextField(
                      controller: ctl,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      decoration: InputDecoration(labelText: 'Paste here', errorText: err, errorMaxLines: 4),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () async {
                          final t = ctl.text.trim();
                          if (t.isEmpty) return;
                          set(() {
                            busy = true;
                            err = null;
                          });
                          try {
                            // Validate against the real service before saving anything.
                            final user = await validate(t);
                            await save(t, user);
                            ctl.clear();
                            if (ctx.mounted) Navigator.pop(ctx);
                          } catch (e) {
                            set(() {
                              busy = false;
                              err = 'Not accepted: $e';
                            });
                          }
                        },
                  child: const Text('Verify & save'),
                ),
              ],
            );
          },
        );
      },
    );
    ctl.dispose();
  }

  Future<void> _githubDevice(BuildContext context) async {
    final clientId = c.settings.githubClientId.isNotEmpty ? c.settings.githubClientId : _builtInGithubClientId;
    if (clientId.isEmpty) {
      toast(
        context,
        'No GitHub OAuth app configured for this build. Use "Use a token" instead, or set a client id in Settings → Advanced.',
      );
      return;
    }
    var cancelled = false;
    DeviceCode code;
    try {
      code = await c.auth.githubStartDeviceFlow(clientId);
    } catch (e) {
      if (context.mounted) toast(context, '$e');
      return;
    }
    if (!context.mounted) return;
    unawaited(openUrl(code.verificationUri));
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign in with GitHub'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Open ${code.verificationUri} and enter this code:'),
            const SizedBox(height: 12),
            SelectableText(code.userCode, style: Theme.of(ctx).textTheme.headlineMedium),
            TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: code.userCode)),
              icon: const Icon(Icons.copy),
              label: const Text('Copy code'),
            ),
            const SizedBox(height: 8),
            const Text('Only approve if YOU started this sign-in and the app name shown on GitHub is what you expect.'),
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.pop(ctx);
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    try {
      final token = await c.auth.githubPollDeviceFlow(clientId, code, cancelled: () => cancelled);
      final user = await c.auth.githubUser(token);
      await c.setCredentials(c.credentials.copyWith(githubToken: token));
      c.settings.githubUser = user;
      await c.saveSettings();
      if (context.mounted) {
        Navigator.of(context).pop();
        toast(context, 'Signed in to GitHub as $user');
      }
    } catch (e) {
      if (!cancelled && context.mounted) {
        Navigator.of(context).pop();
        toast(context, '$e');
      }
    }
    await dialog;
  }

  Future<void> _itchLogin(BuildContext context) async {
    final user = TextEditingController();
    final pass = TextEditingController();
    final totp = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        var busy = false;
        String? err;
        String? totpToken;
        return StatefulBuilder(
          builder: (ctx, set) {
            Future<void> submit() async {
              set(() {
                busy = true;
                err = null;
              });
              try {
                String key;
                if (totpToken == null) {
                  final r = await c.auth.itchLogin(user.text.trim(), pass.text);
                  if (r.totpToken != null) {
                    set(() {
                      totpToken = r.totpToken;
                      busy = false;
                    });
                    return;
                  }
                  key = r.key!;
                } else {
                  key = await c.auth.itchVerifyTotp(totpToken!, totp.text);
                }
                final name = await c.auth.itchUser(key);
                await c.setCredentials(c.credentials.copyWith(itchApiKey: key));
                c.settings.itchUser = name;
                await c.saveSettings();
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (e) {
                set(() {
                  busy = false;
                  err = '$e';
                });
              } finally {
                pass.clear(); // the password never stays in memory longer than needed
              }
            }

            return AlertDialog(
              title: const Text('Sign in to itch.io'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (totpToken == null) ...[
                      TextField(
                        controller: user,
                        autocorrect: false,
                        decoration: const InputDecoration(labelText: 'Username or email'),
                      ),
                      TextField(
                        controller: pass,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(labelText: 'Password'),
                        onSubmitted: (_) => submit(),
                      ),
                    ] else
                      TextField(
                        controller: totp,
                        autofocus: true,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Two-factor code'),
                        onSubmitted: (_) => submit(),
                      ),
                    const SizedBox(height: 8),
                    const Text(
                      'Your password goes only to api.itch.io over HTTPS and is not saved.',
                      style: TextStyle(fontSize: 12),
                    ),
                    if (err != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(err!, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                FilledButton(onPressed: busy ? null : submit, child: const Text('Sign in')),
              ],
            );
          },
        );
      },
    );
    user.dispose();
    pass.dispose();
    totp.dispose();
  }
}

class _ServiceCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String purpose;
  final String? signedInAs;
  final List<Widget> actions;
  final Future<void> Function() onSignOut;
  const _ServiceCard({
    required this.icon,
    required this.title,
    required this.purpose,
    required this.signedInAs,
    required this.actions,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 12),
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (signedInAs != null)
                  Chip(avatar: const Icon(Icons.check_circle, size: 18), label: Text(signedInAs!)),
              ],
            ),
            const SizedBox(height: 6),
            Text(purpose),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (signedInAs == null)
                  ...actions
                else ...[
                  OutlinedButton.icon(
                    onPressed: onSignOut,
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out'),
                  ),
                  ...actions.whereType<OutlinedButton>(),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
