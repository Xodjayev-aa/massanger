import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/errors.dart';
import '../../data/account_repository.dart';
import '../../data/models.dart';

class ProfileState extends Equatable {
  const ProfileState({
    this.status = ProfileStatus.loading,
    this.profile,
    this.saving = false,
    this.error,
  });

  final ProfileStatus status;
  final AccountProfile? profile;
  final bool saving;
  final Object? error;

  bool get isGated => profile?.isGated ?? false;

  ProfileState copyWith({
    ProfileStatus? status,
    AccountProfile? profile,
    bool? saving,
    Object? error = _keep,
  }) =>
      ProfileState(
        status: status ?? this.status,
        profile: profile ?? this.profile,
        saving: saving ?? this.saving,
        error: identical(error, _keep) ? this.error : error,
      );

  static const Object _keep = Object();

  @override
  List<Object?> get props => <Object?>[status, profile, saving, error];
}

enum ProfileStatus { loading, ready, failure }

class ProfileCubit extends Cubit<ProfileState> {
  ProfileCubit(this._accounts) : super(const ProfileState());

  final AccountRepository _accounts;

  Future<void> load() async {
    try {
      final profile = await _accounts.profile();
      emit(state.copyWith(status: ProfileStatus.ready, profile: profile, error: null));
    } catch (error) {
      emit(state.copyWith(status: ProfileStatus.failure, error: error));
    }
  }

  Future<void> save({String? displayName, String? bio}) async {
    emit(state.copyWith(saving: true, error: null));
    try {
      final profile = await _accounts.updateProfile(displayName: displayName, bio: bio);
      emit(state.copyWith(profile: profile, saving: false, status: ProfileStatus.ready));
    } catch (error) {
      emit(state.copyWith(saving: false, error: AppException.wrap(error)));
    }
  }

  /// Upload then point at it — never the reverse, so a failed upload cannot leave a
  /// profile referencing an object that does not exist.
  Future<void> saveAvatar(File file, {String? previousPath}) async {
    emit(state.copyWith(saving: true, error: null));
    try {
      final path = await _accounts.uploadAvatar(file);
      final profile = await _accounts.updateProfile(avatarPath: path);
      emit(state.copyWith(profile: profile, saving: false));
      if (previousPath != null && previousPath != path) {
        await _accounts.removeAvatarObject(previousPath);
      }
    } catch (error) {
      emit(state.copyWith(saving: false, error: AppException.wrap(error)));
    }
  }

  Future<void> clearAvatar() async {
    final previous = state.profile?.avatarPath;
    emit(state.copyWith(saving: true));
    try {
      final profile = await _accounts.updateProfile(clearAvatar: true);
      emit(state.copyWith(profile: profile, saving: false));
      await _accounts.removeAvatarObject(previous);
    } catch (error) {
      emit(state.copyWith(saving: false, error: AppException.wrap(error)));
    }
  }
}
