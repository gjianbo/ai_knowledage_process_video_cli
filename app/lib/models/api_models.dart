class LoginSession {
  const LoginSession({
    required this.id,
    required this.username,
    required this.displayName,
    required this.token,
    required this.tokenType,
    required this.expiresAt,
  });

  final String id;
  final String username;
  final String displayName;
  final String token;
  final String tokenType;
  final String expiresAt;

  factory LoginSession.fromJson(Map<String, dynamic> json) => LoginSession(
    id: json['id'] as String,
    username: json['username'] as String,
    displayName: json['display_name'] as String? ?? json['username'] as String,
    token: json['token'] as String,
    tokenType: json['token_type'] as String? ?? 'Bearer',
    expiresAt: json['expires_at'] as String? ?? '',
  );

  factory LoginSession.fromApiJson(Map<String, dynamic> json) {
    final user = json['user'] as Map<String, dynamic>;
    return LoginSession(
      id: user['id'].toString(),
      username: user['username'] as String,
      displayName: user['displayName'] as String? ?? user['username'] as String,
      token: json['accessToken'] as String,
      tokenType: 'Bearer',
      expiresAt: json['expireAt'] as String? ?? '',
    );
  }
}

class AuthProfile {
  const AuthProfile({
    required this.id,
    required this.username,
    required this.displayName,
  });

  final String id;
  final String username;
  final String displayName;

  factory AuthProfile.fromJson(Map<String, dynamic> json) => AuthProfile(
    id: json['id'] as String,
    username: json['username'] as String,
    displayName: json['displayName'] as String? ?? json['username'] as String,
  );
}

class CategoryOption {
  const CategoryOption({
    required this.id,
    required this.kbId,
    required this.kbName,
    required this.name,
  });

  final String id;
  final String kbId;
  final String kbName;
  final String name;

  String get label => kbName.isEmpty ? name : '$kbName / $name';

  factory CategoryOption.fromJson(Map<String, dynamic> json) => CategoryOption(
    id: json['id'].toString(),
    kbId: json['kb_id'] as String? ?? '',
    kbName: json['kb_name'] as String? ?? '',
    name: json['name'] as String,
  );
}

class UploadResult {
  const UploadResult({
    required this.assetId,
    required this.taskId,
    required this.duplicate,
  });

  final String assetId;
  final String taskId;
  final bool duplicate;

  factory UploadResult.fromJson(Map<String, dynamic> json) => UploadResult(
    assetId: json['id'].toString(),
    taskId: (json['taskId'] ?? json['task_id'] ?? json['id']).toString(),
    duplicate: json['duplicate'] as bool? ?? false,
  );
}

class ProcessingTask {
  const ProcessingTask({
    required this.id,
    required this.status,
    required this.errorMessage,
    required this.progressDone,
    required this.progressTotal,
  });
  final String id;
  final String status;
  final String errorMessage;
  final int progressDone;
  final int progressTotal;

  factory ProcessingTask.fromJson(Map<String, dynamic> json) => ProcessingTask(
    id: json['id'].toString(),
    status: json['status'] as String? ?? 'pending',
    errorMessage: json['errorMessage'] as String? ?? '',
    progressDone: json['progressDone'] as int? ?? 0,
    progressTotal: json['progressTotal'] as int? ?? 0,
  );
}

class UploadLimit {
  const UploadLimit({
    required this.maxSizeMB,
    required this.allowExts,
    required this.remark,
  });
  final int maxSizeMB;
  final List<String> allowExts;
  final String remark;
  factory UploadLimit.fromJson(Map<String, dynamic> json) => UploadLimit(
    maxSizeMB: json['max_size_mb'] as int,
    allowExts: (json['allow_exts'] as List<dynamic>? ?? const [])
        .cast<String>(),
    remark: json['remark'] as String? ?? '',
  );
}

class ClientConfig {
  const ClientConfig({
    required this.documentUpload,
    required this.imageUpload,
    required this.audioUpload,
  });
  final UploadLimit documentUpload;
  final UploadLimit imageUpload;
  final UploadLimit audioUpload;
  factory ClientConfig.fromJson(Map<String, dynamic> json) => ClientConfig(
    documentUpload: UploadLimit.fromJson(
      json['document_upload'] as Map<String, dynamic>,
    ),
    imageUpload: UploadLimit.fromJson(
      json['image_upload'] as Map<String, dynamic>,
    ),
    audioUpload: UploadLimit.fromJson(
      json['audio_upload'] as Map<String, dynamic>,
    ),
  );
  static const defaults = ClientConfig(
    documentUpload: UploadLimit(
      maxSizeMB: 500,
      allowExts: ['pdf', 'doc', 'docx', 'txt', 'md'],
      remark: '',
    ),
    imageUpload: UploadLimit(
      maxSizeMB: 500,
      allowExts: ['jpg', 'jpeg', 'png', 'webp'],
      remark: '',
    ),
    audioUpload: UploadLimit(
      maxSizeMB: 500,
      allowExts: ['mp3', 'wav', 'm4a', 'flac'],
      remark: '',
    ),
  );
}
