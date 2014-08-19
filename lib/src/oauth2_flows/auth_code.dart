library googleapis_auth.auth_code_flow;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http_base/http_base.dart' as http;
import '../utils.dart';
import '../../auth_io.dart';

/// Abstract class for obtaining access credentials via the authorization code
/// grant flow
///
/// See
///   * [AuthorizationCodeGrantServerFlow]
///   * [AuthorizationCodeGrantManualFlow]
/// for further details.
abstract class AuthorizationCodeGrantAbstractFlow {
  final ClientId clientId;
  final List<String> scopes;
  final http.RequestHandler _client;

  AuthorizationCodeGrantAbstractFlow(this.clientId, this.scopes, this._client);

  Future<AccessCredentials> run();

  Future<AccessCredentials> _obtainAccessCredentialsUsingCode(
      String code, String redirectUri) {
    var uri = Uri.parse('https://accounts.google.com/o/oauth2/token');
    var headers = new http.HeadersImpl({
      'content-type' : 'application/x-www-form-urlencoded',
    });

    var formValues = [
        'grant_type=authorization_code',
        'code=${Uri.encodeQueryComponent(code)}',
        'redirect_uri=${Uri.encodeQueryComponent(redirectUri)}',
        'client_id=${Uri.encodeQueryComponent(clientId.identifier)}',
        'client_secret=${Uri.encodeQueryComponent(clientId.secret)}',
    ];

    var body =
        new Stream.fromIterable([ASCII.encode(formValues.join('&'))]);
    var request = new http.RequestImpl(
        'POST', uri, headers: headers, body: body);

    return _client(request).then((http.ResponseImpl response) {
      return response.read()
        .transform(UTF8.decoder)
        .transform(JSON.decoder)
        .first.then((Map json) {

        var tokenType = json['token_type'];
        var accessToken = json['access_token'];
        var seconds = json['expires_in'];
        var refreshToken = json['refresh_token'];
        var error = json['error'];

        if (response.statusCode != 200 && error != null) {
          throw new UserConsentException('Failed to obtain user consent. '
              'Response was ${response.statusCode}. Error message was $error.');
        }

        if (accessToken == null || seconds is! int || tokenType != 'Bearer') {
          throw new Exception(
              'Failed to obtain user consent. Invalid server response.');
        }

        return new AccessCredentials(
            new AccessToken('Bearer', accessToken, expiryDate(seconds)),
            refreshToken,
            scopes);
      });
    });
  }

  String _authenticationUri(String redirectUri, {String state}) {
    // TODO: Increase scopes with [include_granted_scopes].
    var queryValues = [
        'response_type=code',
        'client_id=${Uri.encodeQueryComponent(clientId.identifier)}',
        'redirect_uri=${Uri.encodeQueryComponent(redirectUri)}',
        'scope=${Uri.encodeQueryComponent(scopes.join(' '))}',
    ];
    if (state != null) {
      queryValues.add('state=${Uri.encodeQueryComponent(state)}');
    }
    return Uri.parse('https://accounts.google.com/o/oauth2/auth'
                     '?${queryValues.join('&')}').toString();
  }
}


/// Runs an oauth2 authorization code grant flow using an HTTP server.
///
/// This class is able to run an oauth2 authorization flow. It takes a user
/// supplied function which will be called with an URI. The user is expected
/// to navigate to that URI and to grant access to the client.
///
/// Once the user has granted access to the client, Google will redirect the
/// user agent to a URL pointing to a locally running HTTP server. Which in turn
/// will be able to extract the authorization code from the URL and use it to
/// obtain access credentials.
class AuthorizationCodeGrantServerFlow
    extends AuthorizationCodeGrantAbstractFlow {
  final PromptUserForConsent userPrompt;

  AuthorizationCodeGrantServerFlow(
      ClientId clientId, List<String> scopes, http.RequestHandler client,
      this.userPrompt) : super(clientId, scopes, client);

  Future<AccessCredentials> run() {
    return HttpServer.bind('localhost', 0).then((HttpServer server) {
      var port = server.port;
      var redirectionUri = 'http://localhost:$port';

      // TODO: Make this random??
      var state = 'foobar';

      // Prompt user and wait until he goes to URL and the google authorization
      // server calls back to our locally running HTTP server.
      userPrompt(_authenticationUri(redirectionUri, state: state));

      return server.first.then(((HttpRequest request) {
        var uri = request.uri;

        var returnedState = uri.queryParameters['state'];
        var code = uri.queryParameters['code'];
        var error = uri.queryParameters['error'];

        fail(exception) {
          (request.response..statusCode = 500).close().catchError((_) {});
          throw exception;
        }

        if (request.method != 'GET') {
          fail(new Exception('Invalid response from server '
              '(expected GET request callback, got: ${request.method}).'));
        }

        if (state != returnedState) {
          fail(new Exception(
              'Invalid response from server (state did not match).'));
        }

        if (error != null) {
          fail(new UserConsentException(
              'Error occured while obtaining access credentials: $error'));
        }

        if (code == null || code == '') {
          fail(new Exception(
              'Invalid response from server (no auth code transmitted).'));
        }

        return _obtainAccessCredentialsUsingCode(code, redirectionUri)
            .then((AccessCredentials credentials) {
          // NOTE: We could introduce a user-defined redirect page.
          request.response
              ..statusCode = 200
              ..write('Application has successfully obtained access credentials'
                      '. This window can be closed now.');
          return request.response.close().then((_) => credentials);
        }).catchError((error, stack) {
          return request.response.close()
              .then((_) => new Future.error(error, stack));
        });
      })).whenComplete(() => server.close());
    });
  }
}


/// Runs an oauth2 authorization code grant flow using manual Copy&Paste.
///
/// This class is able to run an oauth2 authorization flow. It takes a user
/// supplied function which will be called with an URI. The user is expected
/// to navigate to that URI and to grant access to the client.
///
/// Google will give the resource owner a code. The user supplied function needs
/// to complete with that code.
///
/// The authorization code will then be used to obtain access credentials.
class AuthorizationCodeGrantManualFlow
    extends AuthorizationCodeGrantAbstractFlow {
  final PromptUserForConsentManual userPrompt;

  AuthorizationCodeGrantManualFlow(
      ClientId clientId, List<String> scopes, http.RequestHandler client,
      this.userPrompt) : super(clientId, scopes, client);

  Future<AccessCredentials> run() {
    var redirectionUri = 'urn:ietf:wg:oauth:2.0:oob';

    // Prompt user and wait until he goes to URL and copy&pastes the auth code
    // in.
    return userPrompt(_authenticationUri(redirectionUri)).then((String code) {
      // Use code to obtain credentials
      return _obtainAccessCredentialsUsingCode(code, redirectionUri);
    });
  }
}


// TODO: Server app flow is missing here.