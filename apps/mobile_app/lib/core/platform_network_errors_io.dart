import 'dart:io';

bool isPlatformNetworkError(Object error) => error is SocketException || error is HttpException;
