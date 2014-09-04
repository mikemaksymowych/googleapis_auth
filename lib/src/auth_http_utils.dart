// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library googleapis_auth;

import 'dart:async';
import 'package:http/http.dart';

import '../auth.dart';
import 'http_client_base.dart';

/// Will close the underlying `http.Client` depending on a constructor argument.
class AuthenticatedClient extends DelegatingClient implements AuthClient {
  final AccessCredentials credentials;

  AuthenticatedClient(Client client, this.credentials)
      : super(client, closeUnderlyingClient: false);

  Future<StreamedResponse> send(BaseRequest request) {
    // Make new request object and perform the authenticated request.
    var modifiedRequest = new RequestImpl(
        request.method, request.url, request.finalize());
    modifiedRequest.headers.addAll(request.headers);
    modifiedRequest.headers['Authorization'] =
        'Bearer ${credentials.accessToken.data}';
    return baseClient.send(modifiedRequest).then((response) {
      var wwwAuthenticate = response.headers['www-authenticate'];
      if (wwwAuthenticate != null) {
        return response.stream.drain().then((_) {
          throw new AccessDeniedException('Access was denied '
              '(www-authenticate header was: $wwwAuthenticate).');
        });
      }
      return response;
    });
  }
}


/// Will close the underlying `http.Client` depending on a constructor argument.
class AutoRefreshingClient extends AutoRefreshDelegatingClient {
  final ClientId clientId;
  AccessCredentials credentials;
  Client authClient;

  AutoRefreshingClient(Client client, this.clientId, this.credentials,
                       {bool closeUnderlyingClient: false})
      : super(client, closeUnderlyingClient: closeUnderlyingClient) {
    assert (credentials.refreshToken != null);
    authClient = authenticatedClient(baseClient, credentials);
  }

  Future<StreamedResponse> send(BaseRequest request) {
    if (!credentials.accessToken.hasExpired) {
      // TODO: Can this return a "access token expired" message?
      // If so, we should handle it.
      return authClient.send(request);
    } else {
      return refreshCredentials(clientId, credentials, baseClient).then((cred) {
        notifyAboutNewCredentials(cred);
        credentials = cred;
        authClient = authenticatedClient(baseClient, cred);
        return authClient.send(request);
      });
    }
  }
}


abstract class AutoRefreshDelegatingClient extends DelegatingClient
                                           implements AutoRefreshingAuthClient {
  final StreamController<AccessCredentials> _credentialStreamController
      = new StreamController.broadcast(sync: true);

  AutoRefreshDelegatingClient(Client client,
                              {bool closeUnderlyingClient: true})
      : super(client, closeUnderlyingClient: closeUnderlyingClient);

  Stream<AccessCredentials> get credentialUpdates =>
      _credentialStreamController.stream;

  void notifyAboutNewCredentials(AccessCredentials credentials) {
    _credentialStreamController.add(credentials);
  }

  void close() {
    _credentialStreamController.close();
    super.close();
  }
}
